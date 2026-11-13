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
            await sessions.deliverSteering(text, panelID: fixture.panelID)
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

        /// The messages Toastty holds for the agent's next open prompt.
        func waiting() -> [String] {
            sessions.steerSender.heldTexts(panelID: fixture.panelID)
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
        #expect(harness.waiting().isEmpty)
    }

    @MainActor
    @Test func aPromptOnScreenHoldsTheMessageUntilTheTurnEnds() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        // The agent asks for a permission. Its transcript does not show
        // that; only its hooks do.
        harness.report(.needsApproval)

        #expect(await harness.send("Use 300 ms") == .success(.queued(position: 1)))
        #expect(harness.typed.texts.isEmpty)
        #expect(harness.waiting() == ["Use 300 ms"])

        // The user answers the prompt and the turn goes on: still held.
        harness.report(.working)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.typed.texts.isEmpty)

        try harness.endTurn()
        try await Transcript.waitUntil("the held message at the next prompt") { harness.typed.texts.isEmpty == false }
        #expect(harness.typed.texts == ["Use 300 ms"])
        #expect(harness.waiting().isEmpty)
    }

    @MainActor
    @Test func aTurnTheUserTypedInHoldsTheMessage() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        #expect(await harness.send("First") == .success(.steered))

        // The user types in the task's terminal during the turn.
        harness.fixture.terminalRuntimeRegistry.handleLocalInput(for: harness.fixture.panelID, kind: .key)

        #expect(await harness.send("Second") == .success(.queued(position: 1)))
        #expect(harness.typed.texts == ["First"])
        #expect(harness.waiting() == ["Second"])
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
        #expect(harness.waiting().isEmpty)

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

        // The conversation knows of the typing: it holds the message for
        // the turn's end, and the send does not fail.
        #expect(await harness.send("Use 300 ms") == .success(.queued(position: 1)))
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
        #expect(harness.waiting().isEmpty)
    }

    @MainActor
    @Test func aNewAgentsHeldMessageStaysWhenTheOldAgentsMessagesAreDropped() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        harness.report(.needsApproval)
        #expect(await harness.send("For the first agent") == .success(.queued(position: 1)))

        let second = harness.replaceAgent()
        harness.fixture.sessionRuntimeStore.updateStatus(
            sessionID: second, status: SessionStatus(kind: .needsApproval, summary: "Needs approval"), at: Date()
        )
        #expect(await harness.send("For the second agent") == .success(.queued(position: 2)))
        try await Transcript.waitUntil("the first agent's message to be dropped") {
            harness.waiting() == ["For the second agent"]
        }
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

        #expect(await harness.send("Use 300 ms") == .success(.queued(position: 1)))
        // Several looks at the open prompt later, it is still held.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(harness.typed.texts.isEmpty)
        #expect(harness.waiting() == ["Use 300 ms"])

        // The hooks report the prompt answered and the agent idle again.
        harness.report(.idle)
        try await Transcript.waitUntil("the held message at the open prompt") { harness.typed.texts.isEmpty == false }
        #expect(harness.typed.texts == ["Use 300 ms"])
    }

    @MainActor
    @Test func heldMessagesAreTypedInOrderOneForEachOpenPrompt() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        harness.report(.needsApproval)
        #expect(await harness.send("First") == .success(.queued(position: 1)))
        #expect(await harness.send("Second") == .success(.queued(position: 2)))

        harness.report(.working)
        try harness.endTurn()
        try await Transcript.waitUntil("the first held message") { harness.typed.texts.isEmpty == false }
        // The first one started a turn. The second waits for that turn's end.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(harness.typed.texts == ["First"])
        #expect(harness.waiting() == ["Second"])
    }

    @MainActor
    @Test func aHeldMessageIsDroppedWhenItsAgentEnds() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        harness.report(.needsApproval)
        #expect(await harness.send("Use 300 ms") == .success(.queued(position: 1)))

        harness.fixture.sessionRuntimeStore.stopSession(sessionID: harness.fixture.sessionID, at: Date())
        try await Transcript.waitUntil("the held message to be dropped") { harness.waiting().isEmpty }
        #expect(harness.typed.texts.isEmpty)
    }

    @MainActor
    @Test func theSixthHeldMessageIsRefused() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.startTurn()
        harness.report(.needsApproval)

        for position in 1...TaskSteerSender.maximumHeldMessages {
            #expect(await harness.send("Message \(position)") == .success(.queued(position: position)))
        }
        #expect(await harness.send("One more") == .failure(.queueFull))
        #expect(harness.typed.texts.isEmpty)
        #expect(harness.waiting().count == TaskSteerSender.maximumHeldMessages)
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
