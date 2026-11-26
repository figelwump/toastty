@testable import ToasttyApp
import CoreState
import Foundation
import RemoteProtocol
import Testing

/// `task send --steer` against a real conversation: what Toastty types, and
/// when, for each thing the task's agent can be doing.
@Suite(.serialized)
struct TaskSteerSenderTests {
    private typealias Transcript = LocalConversationAccessTests

    /// One Codex agent in a terminal panel, and the task sessions that
    /// `task send --steer` uses, with Remote Access off. Nothing follows the
    /// agent's conversation until the first send.
    @MainActor
    private final class Harness {
        let fixture: LocalConversationFixture
        let typed: DeliveredText
        let sessions: LiveTaskSessions

        init() throws {
            fixture = try LocalConversationFixture()
            typed = fixture.captureDeliveredText()
            sessions = LiveTaskSessions(
                sessionRuntimeStore: fixture.sessionRuntimeStore,
                closeController: SessionCloseController(
                    store: fixture.store,
                    sessionRuntimeStore: fixture.sessionRuntimeStore,
                    focusedPanelCommandController: FocusedPanelCommandController(
                        store: fixture.store,
                        runtimeRegistry: fixture.terminalRuntimeRegistry,
                        slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                    ),
                    terminalCloseAssessment: { _ in nil },
                    localDocumentCloseConfirmationState: { _ in nil },
                    shouldBypassConfirmation: true
                ),
                exitController: nil,
                sendText: { _, _ in
                    Issue.record("A checked send must not type through the unchecked path")
                    return false
                }
            )
            sessions.conversationAccess = fixture.service
            #expect(fixture.confirmCurrentLaunchBinding())
        }

        func send(_ text: String) async -> Result<TaskSteerDelivery, TaskSteerFailure> {
            await sessions.deliverSteering(text, panelID: fixture.panelID) { true }
        }

        /// What the agent's hooks report.
        func report(_ kind: SessionStatusKind) {
            fixture.sessionRuntimeStore.updateStatus(
                sessionID: fixture.sessionID,
                status: SessionStatus(kind: kind, summary: kind.rawValue),
                at: Date()
            )
        }

        /// The agent starts a turn: its hooks report it, and its transcript
        /// records the user's message and the turn.
        func startTurn() throws {
            report(.working)
            try fixture.appendToTranscript(Transcript.userMessage("Fix the flicker", at: "2026-08-07T10:00:05.000Z"))
            try fixture.appendToTranscript(Transcript.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        }

        func endTurn() throws {
            try fixture.appendToTranscript(Transcript.taskComplete(at: "2026-08-07T10:00:21.000Z"))
            report(.idle)
        }

        /// The panel's agent ends and another one starts there. Returns the
        /// new session's ID.
        @discardableResult
        func replaceAgent() -> String {
            let selection = fixture.store.state.selectedWorkspaceSelection()!
            let sessionID = "replacement-\(UUID().uuidString)"
            fixture.sessionRuntimeStore.stopSession(sessionID: fixture.sessionID, at: Date())
            fixture.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: fixture.panelID,
                windowID: selection.windowID,
                workspaceID: selection.workspaceID,
                usesSessionStatusNotifications: false,
                codexStatusTrackingSource: .externallyReported,
                cwd: "/repo",
                repoRoot: "/repo",
                at: Date()
            )
            return sessionID
        }

        func tearDown() {
            sessions.conversationAccess = nil
            fixture.removeRuntimeFiles()
        }
    }

    @MainActor
    @Test func anIdleAgentGetsTheMessageAtItsOpenPrompt() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(await harness.send("[coordinator] The user says: use 300 ms") == .success(.sent))
        #expect(harness.typed.texts == ["[coordinator] The user says: use 300 ms"])
        // The sender is not the user at the task's terminal.
        #expect(harness.fixture.service.lastRemoteUserInputAt(panelID: harness.fixture.panelID) == nil)
        #expect(harness.sessions.lastUserInputAt(panelID: harness.fixture.panelID) == nil)
        // Toastty's other messages read when it typed, to leave that prompt.
        #expect(harness.sessions.lastSteerTypedAt(panelID: harness.fixture.panelID) != nil)
    }

    @MainActor
    @Test func anIdleAgentGetsTheMessageAlsoWhenKeysReachedItsTerminalBeforeItsFirstTurn() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        // Keys reached the terminal before the agent started, such as the
        // answer to its folder trust prompt. A conversation that is first
        // followed opens as a draft for them, until it reads the finished
        // turn in the transcript.
        harness.fixture.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: harness.fixture.panelID)
        try harness.startTurn()
        try harness.endTurn()

        #expect(await harness.send("Use 300 ms") == .success(.sent))
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    @MainActor
    @Test func aBusyAgentGetsTheMessageInItsRunningTurn() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()

        // Nothing followed the conversation before this send: it waits
        // until the transcript shows the turn that the hooks report.
        #expect(await harness.send("Use 300 ms") == .success(.steered))
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    @MainActor
    @Test func aPromptOnScreenLeavesTheMessageToWaitForTheTurnsEnd() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        // The agent asks for a permission. Its transcript does not show
        // that; only its hooks do.
        harness.report(.needsApproval)

        // The task coordinator saves it for the next open prompt.
        #expect(await harness.send("Use 300 ms") == .success(.mustWait))
        #expect(harness.typed.texts.isEmpty)

        // At the turn's end, a new send types at once.
        harness.report(.working)
        try harness.endTurn()
        #expect(await harness.send("Use 300 ms") == .success(.sent))
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    @MainActor
    @Test func aTurnTheUserTypedInLeavesTheMessageToWait() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        #expect(await harness.send("First") == .success(.steered))

        // The user types in the task's terminal during the turn.
        harness.fixture.terminalRuntimeRegistry.handleLocalInput(for: harness.fixture.panelID, kind: .key)

        #expect(await harness.send("Second") == .success(.mustWait))
        #expect(harness.typed.texts == ["First"])
    }

    @MainActor
    @Test func aDraftTypedBeforeToasttyFollowedTheConversationStopsTheSend() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        // Typed during the turn, while nothing followed the conversation,
        // and not submitted: the conversation never learns of it, and the
        // turn's end leaves it in the agent's prompt.
        harness.fixture.sessionRuntimeStore.noteUserInput(panelID: harness.fixture.panelID)
        try harness.endTurn()

        #expect(await harness.send("Use 300 ms") == .failure(.typedInTerminal))
        #expect(harness.typed.texts.isEmpty)

        // The next turn starts after that typing, so it takes a message.
        harness.report(.working)
        try harness.fixture.appendToTranscript(Transcript.userMessage("Next", at: "2026-08-07T10:01:05.000Z"))
        try harness.fixture.appendToTranscript(Transcript.taskStarted(at: "2026-08-07T10:01:05.100Z"))
        #expect(await harness.send("Use 300 ms") == .success(.steered))
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    @MainActor
    @Test func typingThatToasttyFollowedDoesNotStopTheFirstSend() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        // Something else follows the panel already, as the gateway does
        // for every agent while Remote Access is on.
        let earlier = harness.fixture.service.subscribeToConversation(inPanel: harness.fixture.panelID)
        defer { earlier.cancel() }
        try harness.startTurn()
        try await Transcript.waitUntil("the running turn") {
            earlier.snapshot(at: .now)?.summary.inputControl?.turnEpoch != nil
        }
        // The user answers a prompt of the agent in the terminal.
        harness.fixture.sessionRuntimeStore.noteUserInput(panelID: harness.fixture.panelID)
        harness.fixture.terminalRuntimeRegistry.handleLocalInput(for: harness.fixture.panelID, kind: .key)

        // The conversation knows of the typing: the message waits for the
        // turn's end, and the send does not fail.
        #expect(await harness.send("Use 300 ms") == .success(.mustWait))
        #expect(harness.typed.texts.isEmpty)
    }

    @MainActor
    @Test func aSendThatWaitsDoesNotReachAnAgentThatReplacedItsOwn() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        // The hooks report a turn that the transcript does not show: the
        // send waits for the two to agree.
        harness.report(.working)
        async let result = harness.send("For the first agent")
        try await Task.sleep(for: .milliseconds(400))

        harness.replaceAgent()
        #expect(await result == .failure(.unavailable))
        #expect(harness.typed.texts.isEmpty)
    }

    @MainActor
    @Test func aPromptThatOnlyTheHooksReportIsNotTypedIntoWhileTheTranscriptShowsAnOpenPrompt() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        // The transcript shows an open prompt after a finished turn, and
        // the hooks say that the agent waits at a prompt of its own: the
        // transcript is behind.
        try harness.startTurn()
        try harness.endTurn()
        harness.report(.needsApproval)

        #expect(await harness.send("Use 300 ms") == .success(.mustWait))
        #expect(harness.typed.texts.isEmpty)

        // The hooks report the prompt answered and the agent idle again.
        harness.report(.idle)
        #expect(await harness.send("Use 300 ms") == .success(.sent))
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    /// Claude Code's own dialogs, such as the compact offer, show no
    /// interaction in the conversation and leave the hooks at rest. Return
    /// picks a choice there, so the message waits until the dialog closes.
    @MainActor
    @Test func aDialogOfTheAgentsOwnLeavesTheMessageToWait() async throws {
        final class Dialog { var shows = true }
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        try harness.endTurn()
        let dialog = Dialog()
        let sender = TaskSteerSender { panelID in
            guard let session = harness.sessions.activeSession(panelID: panelID) else { return nil }
            return TaskSteerAgentView(
                sessionID: session.sessionID,
                state: TaskAgentState(statusKind: session.status?.kind),
                latestTurnStartedAt: session.latestTurnStartedAt,
                showsDialog: dialog.shows
            )
        }
        sender.access = harness.fixture.service
        defer { sender.releasePanels { _ in true } }

        #expect(await sender.send("Use 300 ms", panelID: harness.fixture.panelID) == .success(.mustWait))
        #expect(harness.typed.texts.isEmpty)

        dialog.shows = false
        #expect(await sender.send("Use 300 ms", panelID: harness.fixture.panelID) == .success(.sent))
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    @MainActor
    @Test func aPanelWithNoAgentGetsNothing() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.fixture.sessionRuntimeStore.stopSession(sessionID: harness.fixture.sessionID, at: Date())

        #expect(await harness.send("Use 300 ms") == .failure(.unavailable))
        #expect(harness.typed.texts.isEmpty)
    }
}
