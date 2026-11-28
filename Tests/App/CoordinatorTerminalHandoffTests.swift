import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Sign In and Continue in Terminal for a coordinator that is a direct
/// session: both hand work to the coordinator's terminal, which is a plain
/// shell. The controller runs a real `ClaudeDirectSession` here, against a
/// script that stands in for Claude Code in stream-json mode. The test
/// gives the start report of Claude Code's hooks itself.
@MainActor
struct CoordinatorTerminalHandoffTests {
    /// Answers Toastty's start request with a Claude plan when the file
    /// `signed-in` is beside the script, and with no plan otherwise. A
    /// message starts a turn that does not end.
    static let claudeStandIn = #"""
    #!/bin/sh
    directory=$(dirname "$0")
    while IFS= read -r line; do
      case "$line" in
        *'"subtype":"initialize"'*)
          id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
          if [ -f "$directory/signed-in" ]; then account='{"subscriptionType":"Claude Max"}'; else account='{"tokenSource":"none"}'; fi
          printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"account":%s,"commands":[{"name":"toastty-coordinator"}]}}}\n' "$id" "$account"
          ;;
        *'"type":"user"'*)
          printf '{"type":"system","subtype":"init","session_id":"native-direct","apiKeySource":"none"}\n'
          ;;
      esac
    done
    """#

    @MainActor
    final class Host: DirectConversationSessionHost {
        private(set) var attached: [any DirectConversationSession] = []

        func attachDirectSession(_ session: any DirectConversationSession) {
            if attached.contains(where: { $0 === session }) == false { attached.append(session) }
        }

        func detachDirectSession(_ session: any DirectConversationSession) {
            attached.removeAll { $0 === session }
        }

        func ingestDirectSessionObservations(
            _ observations: [ProviderTranscriptObservation],
            from session: any DirectConversationSession
        ) {}
    }

    @MainActor
    final class Fixture {
        let base: CoordinatorControllerTests.Fixture
        let host = Host()
        let nativeSessionID = UUID().uuidString.lowercased()

        init() throws {
            base = try CoordinatorControllerTests.Fixture(directSession: true)
            let script = bin.appendingPathComponent("claude")
            try Data(CoordinatorTerminalHandoffTests.claudeStandIn.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            base.controller.directSessionHost = host
        }

        var controller: CoordinatorController { base.controller }
        var router: TestTerminalCommandRouter { base.tasks.router }
        private var bin: URL { base.tasks.root.appendingPathComponent("bin", isDirectory: true) }
        var transcript: URL { base.tasks.root.appendingPathComponent("\(nativeSessionID).jsonl") }

        func panelID() throws -> UUID {
            try #require(controller.location?.panelID)
        }

        /// The user finished the sign-in: Claude Code has a plan from now on.
        func signInToClaude() throws {
            try Data().write(to: bin.appendingPathComponent("signed-in"))
        }

        /// Gives each start of a direct session what Claude Code's hooks
        /// report: the start, and the conversation with its transcript.
        /// The app also saves that conversation on the terminal's panel.
        func reportStartsFromTheHooks() -> Task<Void, Never> {
            Task { @MainActor [self] in
                var reported: Set<String> = []
                while Task.isCancelled == false {
                    // A restart plans its session for a new terminal.
                    let panelIDs = controller.location.flatMap { base.store.state.workspacesByID[$0.workspaceID] }
                        .map { workspace in workspace.orderedTabs.flatMap(\.allPanelIDs) } ?? []
                    for panelID in panelIDs {
                        guard let session = base.sessions.sessionRegistry.activeSession(for: panelID),
                              reported.contains(session.sessionID) == false else { continue }
                        reported.insert(session.sessionID)
                        let record = ManagedAgentResumeRecord(
                            agent: .claude,
                            nativeSessionID: nativeSessionID,
                            sessionFilePath: transcript.path,
                            cwd: base.directory.path,
                            capturedAt: Date()
                        )
                        base.sessions.noteStartReportFromHook(sessionID: session.sessionID)
                        _ = base.sessions.confirmNativeSessionBinding(
                            managedSessionID: session.sessionID,
                            panelID: panelID,
                            record: record
                        )
                        _ = base.store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record))
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        /// Starts the coordinator as a direct session that runs.
        func openAsDirectSession() async throws {
            try signInToClaude()
            try Data("{}\n".utf8).write(to: transcript)
            let hooks = reportStartsFromTheHooks()
            defer { hooks.cancel() }
            _ = try await controller.open()
            #expect(try base.status().agentState == .running)
            #expect(try base.status().agentIsDirectSession)
            #expect(controller.offersContinueInTerminal)
        }
    }

    // MARK: - Sign In

    @Test func signInRunsInTheTerminalAndTheCoordinatorStartsWhenItEnds() async throws {
        let fixture = try Fixture()
        // Claude Code has no plan sign-in: the start fails before any
        // message, and the failure offers the sign-in.
        await #expect(throws: CoordinatorError.self) { try await fixture.controller.open() }
        let panelID = try fixture.panelID()
        var status = try fixture.base.status()
        #expect(status.agentState == .notRunning)
        #expect(status.startFailureNeedsSignIn)
        #expect(status.startFailure?.contains("without a Claude plan sign-in") == true)
        #expect(fixture.router.sentTextByPanelID[panelID] == nil)

        // Sign In types the sign-in command of the profile's Claude Code
        // into the terminal's shell, and shows the terminal. Toastty's
        // launcher for agent commands passes it on: it starts no session.
        try fixture.controller.signIn()
        let command = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(command.hasSuffix("/bin/claude auth login\n"))
        #expect(command.hasPrefix("TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1 "))
        #expect(fixture.controller.session == nil)
        #expect(fixture.controller.showsTerminal)
        #expect(try fixture.base.status().awaitsSignIn)

        // The user gives the sign-in up. The command ends, the start fails
        // for the same reason, and the failure offers the sign-in again.
        fixture.router.promptStateByPanelID[panelID] = .busy
        try await Task.sleep(for: CoordinatorController.signInPollInterval * 2)
        #expect(try fixture.base.status().awaitsSignIn)
        fixture.router.promptStateByPanelID[panelID] = .idleAtPrompt
        await fixture.base.waitUntil("the second failed start") {
            guard let status = try? fixture.base.status() else { return false }
            return status.awaitsSignIn == false && status.startFailureNeedsSignIn
        }
        status = try fixture.base.status()
        #expect(status.awaitsSignIn == false)
        #expect(status.agentState == .notRunning)
        #expect(fixture.controller.showsTerminal)

        // The user signs in. When the command ends, the coordinator starts
        // as a direct session by itself, and the chat shows again.
        let hooks = fixture.reportStartsFromTheHooks()
        defer { hooks.cancel() }
        try fixture.controller.signIn()
        fixture.router.promptStateByPanelID[panelID] = .busy
        try await Task.sleep(for: CoordinatorController.signInPollInterval * 2)
        try fixture.signInToClaude()
        fixture.router.promptStateByPanelID[panelID] = .idleAtPrompt
        await fixture.base.waitUntil("the start after the sign-in", timeout: .seconds(10)) {
            (try? fixture.base.status())?.agentState == .running && fixture.controller.showsTerminal == false
        }
        status = try fixture.base.status()
        #expect(status.agentIsDirectSession)
        #expect(status.startFailure == nil)
        #expect(status.awaitsSignIn == false)
        // The sign-in command was the only text typed into the terminal.
        #expect(fixture.router.sendAttemptCount == 2)
    }

    @Test func signInIsRefusedWhileTheTerminalRunsACommand() async throws {
        let fixture = try Fixture()
        await #expect(throws: CoordinatorError.self) { try await fixture.controller.open() }
        let panelID = try fixture.panelID()
        // The user runs a program in the plain shell: the command would go
        // to that program.
        fixture.router.promptStateByPanelID[panelID] = .busy
        #expect(throws: CoordinatorError(CoordinatorController.busyTerminalReason)) {
            try fixture.controller.signIn()
        }
        #expect(fixture.router.sendAttemptCount == 0)
        #expect(try fixture.base.status().awaitsSignIn == false)
        #expect(try fixture.base.status().startFailureNeedsSignIn)
    }

    @Test func aRestartEndsTheWaitForTheSignIn() async throws {
        let fixture = try Fixture()
        await #expect(throws: CoordinatorError.self) { try await fixture.controller.open() }
        let panelID = try fixture.panelID()
        try fixture.controller.signIn()
        fixture.router.promptStateByPanelID[panelID] = .busy
        #expect(try fixture.base.status().awaitsSignIn)

        // The user signs in and restarts by hand while the command runs.
        try fixture.signInToClaude()
        let hooks = fixture.reportStartsFromTheHooks()
        defer { hooks.cancel() }
        _ = try await fixture.controller.restart()
        let sessionID = try fixture.base.session().sessionID
        #expect(try fixture.base.status().agentIsDirectSession)
        // The end of the command starts nothing more.
        fixture.router.promptStateByPanelID[panelID] = .idleAtPrompt
        try await Task.sleep(for: CoordinatorController.signInPollInterval * 4)
        #expect(try fixture.base.session().sessionID == sessionID)
        #expect(try fixture.base.status().awaitsSignIn == false)
    }

    // MARK: - Continue in Terminal

    @Test func continueInTerminalResumesTheSameConversationInTheTerminal() async throws {
        let fixture = try Fixture()
        try await fixture.openAsDirectSession()
        let panelID = try fixture.panelID()
        let directSessionID = try fixture.base.session().sessionID
        #expect(fixture.router.sendAttemptCount == 0)

        try await fixture.controller.continueInTerminal()

        // The terminal got the launch that resumes the conversation, as an
        // interactive Claude Code: no stream-json arguments.
        let command = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(command.contains("/bin/claude"))
        #expect(command.contains("--resume \(fixture.nativeSessionID)"))
        #expect(command.contains("stream-json") == false)
        // The agent in the terminal is a new managed session, and no
        // direct session.
        let session = try fixture.base.session()
        #expect(session.sessionID != directSessionID)
        #expect(session.panelID == panelID)
        #expect(try fixture.base.status().agentIsDirectSession == false)
        #expect(fixture.controller.offersContinueInTerminal == false)
        #expect(fixture.host.attached.isEmpty)
        #expect(fixture.controller.showsTerminal)
        // The way back: with the setting still on, the next launch goes
        // on with this conversation as a direct session.
        #expect(fixture.controller.resumesAsDirectSession(panelID: panelID))
    }

    @Test func continueInTerminalIsRefusedWhileATurnRuns() async throws {
        let fixture = try Fixture()
        try await fixture.openAsDirectSession()
        let panelID = try fixture.panelID()
        let direct = try #require(fixture.host.attached.first)
        #expect(direct.send(text: "Work on this", clientRequestID: "m1", deliveryMode: .prompt) == .delivered)
        // Claude Code reports the turn.
        await fixture.base.waitUntil("the running turn") {
            direct.currentStateObservations().contains { observation in
                if case .turnStarted = observation.payload { return true }
                return false
            }
        }

        await #expect(throws: CoordinatorError.self) { try await fixture.controller.continueInTerminal() }

        // Nothing changed: the direct session runs, and nothing was typed.
        #expect(fixture.router.sendAttemptCount == 0)
        #expect(fixture.controller.offersContinueInTerminal)
        #expect(try fixture.base.status().agentIsDirectSession)
        #expect(fixture.host.attached.count == 1)
        #expect(fixture.router.sentTextByPanelID[panelID] == nil)
    }

    @Test func continueInTerminalIsRefusedWhileTheTerminalRunsACommand() async throws {
        let fixture = try Fixture()
        try await fixture.openAsDirectSession()
        let panelID = try fixture.panelID()
        fixture.router.promptStateByPanelID[panelID] = .busy

        await #expect(throws: CoordinatorError(CoordinatorController.busyTerminalReason)) {
            try await fixture.controller.continueInTerminal()
        }

        // The direct session was not ended for a launch that cannot be typed.
        #expect(fixture.controller.offersContinueInTerminal)
        #expect(fixture.host.attached.count == 1)
        #expect(fixture.router.sendAttemptCount == 0)
    }
}
