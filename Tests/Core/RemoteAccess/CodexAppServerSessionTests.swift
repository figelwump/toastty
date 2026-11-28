import Foundation
import RemoteProtocol
import Testing
@testable import CoreState

/// Drives `CodexAppServerSession` with the lines that `codex app-server`
/// 0.172.0 wrote, shortened to the fields that the session reads. A
/// projector with `hostReadsTurnState` takes the observations, as in the app.
struct CodexAppServerSessionTests {
    // MARK: - The start

    @Test func aStartWithAnAPIKeyFailsBeforeAnyMessage() throws {
        var session = CodexAppServerSession(settings: Self.settings, identity: "test")
        let initialize = try Self.requiredObject(session.startLines().first)
        #expect(initialize["method"] as? String == "initialize")
        let afterInitialize = session.receive(line: Self.result(1, #"{"codexHome":"/Users/me/.codex"}"#), at: Self.start)
        let written = try Self.written(afterInitialize).map(Self.object)
        #expect(written.map { $0["method"] as? String } == ["initialized", "account/read"])

        let outputs = session.receive(
            line: Self.result(2, #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#),
            at: Self.start
        )
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the start to fail, got \(outputs)")
            return
        }
        #expect(reason.contains("without a ChatGPT plan sign-in"))
        let refused = session.messageLine(text: "hello", clientRequestID: "m1")
        #expect(refused == nil)
        let ignored = session.receive(line: Self.threadAnswer(4), at: Self.start)
        #expect(ignored.isEmpty)
    }

    @Test func aStartWithoutTheRequiredSkillFails() throws {
        let requirements = CodexAppServerSession.Requirements(anyOfSkills: ["toastty:toastty-coordinator", "toastty-coordinator"])
        var session = CodexAppServerSession(requirements: requirements, settings: Self.settings, identity: "test")
        _ = session.startLines()
        _ = session.receive(line: Self.result(1, "{}"), at: Self.start)
        let asked = try Self.written(session.receive(line: Self.accountAnswer(2), at: Self.start)).map(Self.object)
        #expect(asked.map { $0["method"] as? String } == ["skills/list"])
        let outputs = session.receive(
            line: Self.result(3, #"{"data":[{"cwd":"/work","skills":[{"name":"deep-research","enabled":true},{"name":"toastty:toastty-coordinator","enabled":false}],"errors":[]}]}"#),
            at: Self.start
        )
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the start to fail, got \(outputs)")
            return
        }
        #expect(reason.contains("without Toastty's skills"))

        var withSkill = CodexAppServerSession(requirements: requirements, settings: Self.settings, identity: "test")
        _ = withSkill.startLines()
        _ = withSkill.receive(line: Self.result(1, "{}"), at: Self.start)
        _ = withSkill.receive(line: Self.accountAnswer(2), at: Self.start)
        let started = try Self.written(withSkill.receive(
            line: Self.result(3, #"{"data":[{"cwd":"/work","skills":[{"name":"toastty:toastty-coordinator","enabled":true}],"errors":[]}]}"#),
            at: Self.start
        )).map(Self.object)
        #expect(started.map { $0["method"] as? String } == ["thread/start"])
    }

    /// The account is Codex's own sign-in. A conversation that uses another
    /// model provider, from the configuration or from the saved thread,
    /// would bill that provider's key.
    @Test func aThreadWithAnotherModelProviderFailsBeforeAnyMessage() {
        var session = CodexAppServerSession(settings: .init(directory: "/work", resumeThreadID: Self.threadID), identity: "test")
        _ = session.startLines()
        _ = session.receive(line: Self.result(1, "{}"), at: Self.start)
        _ = session.receive(line: Self.accountAnswer(2), at: Self.start)
        let outputs = session.receive(
            line: Self.threadAnswer(3).replacingOccurrences(of: #""modelProvider":"openai""#, with: #""modelProvider":"azure""#),
            at: Self.start
        )
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the start to fail, got \(outputs)")
            return
        }
        #expect(reason.contains(#"model provider "azure""#))
        let refused = session.messageLine(text: "hello", clientRequestID: "m1")
        #expect(refused == nil)
    }

    @Test func theThreadRequestCarriesTheSettingsAndTheAnswerOpensThePrompt() throws {
        var session = CodexAppServerSession(
            settings: .init(directory: "/work", model: "gpt-6.2-sol", approvalPolicy: "on-request", sandbox: "workspace-write"),
            identity: "test"
        )
        _ = session.startLines()
        _ = session.receive(line: Self.result(1, "{}"), at: Self.start)
        let request = try Self.requiredObject(Self.written(session.receive(line: Self.accountAnswer(2), at: Self.start)).first)
        #expect(request["method"] as? String == "thread/start")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["cwd"] as? String == "/work")
        #expect(params["model"] as? String == "gpt-6.2-sol")
        #expect(params["approvalPolicy"] as? String == "on-request")
        #expect(params["sandbox"] as? String == "workspace-write")

        let outputs = session.receive(line: Self.threadAnswer(3), at: Self.start)
        #expect(outputs.first == .conversation(.init(nativeSessionID: Self.threadID, transcriptPath: Self.rolloutPath)))
        guard case .ready(let details)? = outputs.dropFirst().first else {
            Issue.record("Expected the session to be ready, got \(outputs)")
            return
        }
        #expect(details["plan"] == "pro")
        #expect(details["codex_version"] == "0.172.0")
        var projector = Self.projector()
        Self.ingest(outputs, into: &projector)
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected an open prompt, got \(projector.inputAvailability)")
            return
        }
        #expect(projector.executionProfile == RemoteSessionExecutionProfile(modelIdentifier: "gpt-6.2-sol", reasoningEffort: "high"))
    }

    @Test func aResumeAsksForTheSavedConversation() throws {
        var session = CodexAppServerSession(
            settings: .init(directory: "/work", resumeThreadID: Self.threadID),
            identity: "test"
        )
        _ = session.startLines()
        _ = session.receive(line: Self.result(1, "{}"), at: Self.start)
        let request = try Self.requiredObject(Self.written(session.receive(line: Self.accountAnswer(2), at: Self.start)).first)
        #expect(request["method"] as? String == "thread/resume")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["threadId"] as? String == Self.threadID)
        #expect(params["excludeTurns"] as? Bool == true)

        let outputs = session.receive(
            line: #"{"id":3,"error":{"code":-32600,"message":"no rollout found for thread id \#(Self.threadID)"}}"#,
            at: Self.start
        )
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the start to fail, got \(outputs)")
            return
        }
        #expect(reason.contains("could not go on with the saved conversation"))
    }

    // MARK: - A turn

    @Test func aMessageGetsItsReceiptAndTheTurnsEndOpensThePrompt() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)

        let line = try Self.requiredObject(session.messageLine(text: "Reply with pong", clientRequestID: "m1"))
        #expect(line["method"] as? String == "turn/start")
        let params = try #require(line["params"] as? [String: Any])
        #expect(params["threadId"] as? String == Self.threadID)
        #expect(params["clientUserMessageId"] as? String == "m1")
        let requestID = try #require(line["id"] as? Int)

        // Codex's answer to the request starts no turn: its own report does.
        var outputs = session.receive(line: Self.result(requestID, #"{"turn":{"id":"turn-1","status":"inProgress"}}"#), at: Self.start)
        #expect(outputs.isEmpty)
        #expect(session.isTurnRunning == false)
        outputs = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        #expect(outputs.filter { $0 == .turnStarted }.count == 1)
        #expect(session.isTurnRunning)
        Self.ingest(outputs, into: &projector)
        #expect(projector.state == .working)

        outputs = session.receive(line: Self.userItem(id: "item-u1", clientID: "m1", text: "Reply with pong"), at: Self.start)
        outputs += session.receive(line: Self.agentItem(id: "msg_1", text: "pong", phase: "final_answer"), at: Self.start)
        Self.ingest(outputs, into: &projector)
        let rows = Self.transcript(outputs)
        guard case .transcript(.userMessage(let user))? = rows.first?.payload,
              case .transcript(.assistantMessage(let assistant))? = rows.last?.payload else {
            Issue.record("Expected the user's message and Codex's answer, got \(rows)")
            return
        }
        #expect(user.text == "Reply with pong")
        #expect(user.origin == .remote)
        #expect(user.clientRequestID == "m1")
        #expect(user.deliveryMode == nil)
        #expect(assistant.text == "pong")
        // The rows do not start or end the turn.
        #expect(rows.allSatisfy { $0.mayAuthorizeCurrentRuntime == false })

        outputs = session.receive(line: Self.turnCompleted("turn-1", status: "completed"), at: Self.start)
        Self.ingest(outputs, into: &projector)
        #expect(outputs.last == .turnEnded(.init(
            clientRequestIDs: ["m1"], failed: false, interrupted: false, lastMessage: "pong"
        )))
        #expect(session.isTurnRunning == false)
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected an open prompt, got \(projector.inputAvailability)")
            return
        }
    }

    /// Codex gives a user message and its own message the same ID in the
    /// rollout file and on the app-server, so a projection that reads both
    /// has each row once.
    @Test func aMessageHasTheFingerprintOfTheRolloutFilesRecord() throws {
        var session = Self.readySession()
        _ = session.messageLine(text: "Reply with pong", clientRequestID: "m1")
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        let stream = Self.transcript(
            session.receive(line: Self.userItem(id: "01a2234b-8724-7002-b40c-869e5228920a", clientID: "m1", text: "Reply with pong"), at: Self.start)
                + session.receive(line: Self.agentItem(id: "msg_0e1d81caf93644a6", text: "pong", phase: "final_answer"), at: Self.start)
        )

        var parser = CodexRolloutTranscriptParser()
        let file = [
            #"{"timestamp":"2026-11-28T17:54:42.085Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"turn-1","item":{"type":"UserMessage","id":"01a2234b-8724-7002-b40c-869e5228920a","client_id":"m1","content":[{"type":"text","text":"Reply with pong","text_elements":[]}]}}}"#,
            #"{"timestamp":"2026-11-28T17:54:43.092Z","type":"response_item","payload":{"type":"message","status":"completed","id":"msg_0e1d81caf93644a6","role":"assistant","content":[{"type":"output_text","text":"pong","annotations":[],"logprobs":[]}],"phase":"final_answer"}}"#,
        ].flatMap { parser.parseLine($0) }
        #expect(stream.map(\.fingerprint) == file.map(\.fingerprint))
        #expect(stream.map(\.fingerprint) == ["user_item:01a2234b-8724-7002-b40c-869e5228920a", "msg:msg_0e1d81caf93644a6"])
    }

    @Test func aSteerGoesIntoTheRunningTurn() throws {
        var session = Self.readySession()
        _ = session.messageLine(text: "Run sleep 6", clientRequestID: "m1")
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)

        let steer = try Self.requiredObject(session.messageLine(text: "Also say SECOND", clientRequestID: "m2", deliveryMode: .steer))
        #expect(steer["method"] as? String == "turn/steer")
        let params = try #require(steer["params"] as? [String: Any])
        #expect(params["expectedTurnId"] as? String == "turn-1")
        #expect(params["clientUserMessageId"] as? String == "m2")

        let receipt = Self.transcript(session.receive(line: Self.userItem(id: "item-u2", clientID: "m2", text: "Also say SECOND"), at: Self.start))
        guard case .transcript(.userMessage(let user))? = receipt.first?.payload else {
            Issue.record("Expected the steer's receipt, got \(receipt)")
            return
        }
        #expect(user.clientRequestID == "m2")
        #expect(user.deliveryMode == .steer)

        let end = session.receive(line: Self.turnCompleted("turn-1", status: "completed"), at: Self.start)
        guard case .turnEnded(let turnEnd)? = end.last else {
            Issue.record("Expected the turn's end, got \(end)")
            return
        }
        #expect(turnEnd.clientRequestIDs == ["m2"])
    }

    /// The turn can end between the moment the host sends a steer and the
    /// moment Codex reads it. Codex then refuses the steer. The message is
    /// not lost: it starts a turn of its own.
    @Test func aSteerThatCodexRefusesStartsATurnOfItsOwn() throws {
        var session = Self.readySession()
        _ = session.messageLine(text: "Run sleep 6", clientRequestID: "m1")
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        let steer = try Self.requiredObject(session.messageLine(text: "Also say SECOND", clientRequestID: "m2", deliveryMode: .steer))
        let steerID = try #require(steer["id"] as? Int)
        _ = session.receive(line: Self.turnCompleted("turn-1", status: "completed"), at: Self.start)

        let outputs = session.receive(
            line: #"{"id":\#(steerID),"error":{"code":-32600,"message":"no active turn to steer"}}"#,
            at: Self.start
        )
        let again = try Self.requiredObject(Self.written(outputs).first)
        #expect(again["method"] as? String == "turn/start")
        let params = try #require(again["params"] as? [String: Any])
        #expect(params["clientUserMessageId"] as? String == "m2")
        #expect(((params["input"] as? [[String: Any]])?.first?["text"] as? String) == "Also say SECOND")
        #expect(session.phase == .ready)
    }

    @Test func anInterruptEndsTheTurnAndThePromptOpens() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        let noTurn = session.interruptLine()
        #expect(noTurn == nil)
        _ = session.messageLine(text: "Run sleep 30", clientRequestID: "m1")
        Self.ingest(session.receive(line: Self.turnStarted("turn-1"), at: Self.start), into: &projector)

        let interrupt = try Self.requiredObject(session.interruptLine())
        #expect(interrupt["method"] as? String == "turn/interrupt")
        #expect((interrupt["params"] as? [String: Any])?["turnId"] as? String == "turn-1")
        // The turn runs until Codex says that it ended.
        #expect(session.isTurnRunning)

        let outputs = session.receive(line: Self.turnCompleted("turn-1", status: "interrupted"), at: Self.start)
        Self.ingest(outputs, into: &projector)
        guard case .turnEnded(let turnEnd)? = outputs.last else {
            Issue.record("Expected the turn's end, got \(outputs)")
            return
        }
        #expect(turnEnd.interrupted)
        #expect(turnEnd.failed == false)
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected an open prompt, got \(projector.inputAvailability)")
            return
        }
        #expect(projector.events.contains { event in
            guard case .statusChanged(let payload) = event.payload else { return false }
            return payload.state == .interrupted
        })
    }

    /// A command can end after the turn that started it, and Codex then
    /// reports the command's end with no turn running. Only Codex's own
    /// report starts a turn, so the prompt stays open.
    @Test func aCommandThatEndsAfterItsTurnStartsNoTurn() {
        var session = Self.readySession()
        var projector = Self.projector()
        _ = session.messageLine(text: "Run sleep 30", clientRequestID: "m1")
        Self.ingest(session.receive(line: Self.turnStarted("turn-1"), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.commandItem("item/started", status: "inProgress"), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.turnCompleted("turn-1", status: "interrupted"), at: Self.start), into: &projector)

        let late = session.receive(line: Self.commandItem("item/completed", status: "failed", exitCode: 143), at: Self.start)
        Self.ingest(late, into: &projector)
        #expect(late.contains(.turnStarted) == false)
        #expect(session.isTurnRunning == false)
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected the prompt to stay open, got \(projector.inputAvailability)")
            return
        }
        // The end of a turn that does not run changes nothing.
        let again = session.receive(line: Self.turnCompleted("turn-1", status: "completed"), at: Self.start)
        #expect(again.isEmpty)
        // Codex can answer the request that started a turn after the turn's
        // end. The answer does not start the turn a second time.
        let lateAnswer = session.receive(line: Self.result(4, #"{"turn":{"id":"turn-1","status":"inProgress"}}"#), at: Self.start)
        #expect(lateAnswer.isEmpty)
        #expect(session.isTurnRunning == false)
        _ = session.receive(line: Self.turnStarted("turn-2"), at: Self.start)
        let other = session.receive(line: Self.turnCompleted("turn-1", status: "completed"), at: Self.start)
        #expect(other.isEmpty)
        #expect(session.isTurnRunning)
    }

    @Test func aFailedTurnCarriesCodexsError() {
        var session = Self.readySession()
        _ = session.messageLine(text: "hello", clientRequestID: "m1")
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        _ = session.receive(
            line: #"{"method":"error","params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","willRetry":true,"error":{"message":"stream disconnected"}}}"#,
            at: Self.start
        )
        let outputs = session.receive(
            line: #"{"method":"turn/completed","params":{"threadId":"\#(Self.threadID)","turn":{"id":"turn-1","status":"failed","error":{"message":"You've hit your usage limit."}}}}"#,
            at: Self.start
        )
        #expect(outputs.last == .turnEnded(.init(
            clientRequestIDs: [], failed: true, interrupted: false, errorMessage: "You've hit your usage limit."
        )))

        // Codex passes the provider's error on as the provider sent it.
        let fromProvider = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-0' model is not supported."}}"#
        #expect(CodexAppServerSession.readableError(fromProvider) == "The 'gpt-0' model is not supported.")
        #expect(CodexAppServerSession.readableError("Error running remote compact task: \(fromProvider)")
            == "Error running remote compact task: The 'gpt-0' model is not supported.")
        #expect(CodexAppServerSession.readableError("stream disconnected") == "stream disconnected")
    }

    @Test func aCommandShowsAsAToolCall() {
        var session = Self.readySession()
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        let started = Self.transcript(session.receive(line: Self.commandItem("item/started", status: "inProgress"), at: Self.start))
        let finished = Self.transcript(session.receive(line: Self.commandItem("item/completed", status: "completed", exitCode: 0), at: Self.start))
        guard case .transcript(.toolStarted(let call))? = started.first?.payload,
              case .transcript(.toolFinished(let result))? = finished.first?.payload else {
            Issue.record("Expected a tool call and its end, got \(started) and \(finished)")
            return
        }
        #expect(call.callID == "exec-1")
        #expect(call.detail == "/bin/zsh -lc 'touch probe-a.txt'")
        #expect(result.callID == "exec-1")
        #expect(result.outcome == .succeeded)
    }

    /// A subagent's thread reports through the same process. Its turns are
    /// not the conversation's, and its requests are not shown.
    @Test func anotherThreadDoesNotTouchTheConversation() throws {
        var session = Self.readySession()
        let other = #"{"method":"turn/started","params":{"threadId":"other-thread","turn":{"id":"turn-x","status":"inProgress"}}}"#
        let ignored = session.receive(line: other, at: Self.start)
        #expect(ignored.isEmpty)
        #expect(session.isTurnRunning == false)

        let request = #"{"method":"item/commandExecution/requestApproval","id":7,"params":{"threadId":"other-thread","turnId":"turn-x","itemId":"exec-9","command":"rm -rf /","availableDecisions":["accept","cancel"]}}"#
        let answer = try Self.requiredObject(Self.written(session.receive(line: request, at: Self.start)).first)
        #expect(answer["id"] as? Int == 7)
        #expect((answer["result"] as? [String: Any])?["decision"] as? String == "decline")
        #expect(session.waitingRequest == nil)
    }

    @Test func aSignInThatChangesToAnAPIKeyStopsTheSession() {
        var session = Self.readySession()
        let unchanged = session.receive(
            line: #"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"pro","reason":"workspaceRoutingReady"}}"#,
            at: Self.start
        )
        #expect(unchanged.isEmpty)
        let outputs = session.receive(
            line: #"{"method":"account/updated","params":{"authMode":"apikey","planType":null,"reason":null}}"#,
            at: Self.start
        )
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the session to stop, got \(outputs)")
            return
        }
        #expect(reason.contains("not a ChatGPT plan"))
        let refused = session.messageLine(text: "hello", clientRequestID: "m1")
        #expect(refused == nil)
    }

    // MARK: - Requests

    @Test func aCommandApprovalTakesOneAnswer() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.receive(line: Self.turnStarted("turn-1"), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.commandItem("item/started", status: "inProgress"), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.commandApproval(id: 0), at: Self.start), into: &projector)

        let interaction = try #require(projector.pendingInteractions.first)
        #expect(interaction.kind == .permission)
        #expect(interaction.options.map(\.id) == ["allow", "always:0", "deny"])
        #expect(interaction.options[1].label == "Always allow commands that start with touch probe-a.txt")
        #expect(interaction.permission?.preview == "/bin/zsh -lc 'touch probe-a.txt'\n\nin /work")
        let responseID = try #require(interaction.responseID)
        #expect(session.waitingRequest == .init(requestID: responseID, permissionSummary: "Codex asks to run a command"))
        guard case .pendingInteraction = projector.inputAvailability else {
            Issue.record("Expected a waiting request, got \(projector.inputAvailability)")
            return
        }

        // An option that the request does not offer.
        let invalid = session.answer(responseID: responseID, answers: [Self.choice("always:5")], at: Self.start)
        #expect(invalid == .invalid)
        #expect(session.waitingRequest != nil)

        guard case .submitted(let line, let observations) = session.answer(
            responseID: responseID, answers: [Self.choice("allow")], at: Self.start
        ) else {
            Issue.record("Expected the answer to be taken")
            return
        }
        let answer = try Self.object(line)
        #expect(answer["id"] as? Int == 0)
        #expect((answer["result"] as? [String: Any])?["decision"] as? String == "accept")
        Self.ingest(observations, into: &projector)
        #expect(projector.pendingInteractions.isEmpty)
        #expect(projector.state == .working)
        #expect(session.waitingRequest == nil)

        // Codex ignores a second answer, so the session gives none.
        let second = session.answer(responseID: responseID, answers: [Self.choice("deny")], at: Self.start)
        #expect(second == .notPending)
        // Codex's own note that the request has its answer changes nothing.
        let resolved = session.receive(
            line: #"{"method":"serverRequest/resolved","params":{"threadId":"\#(Self.threadID)","requestId":0}}"#,
            at: Self.start
        )
        #expect(resolved.isEmpty)
    }

    @Test func aDenyStopsTheTurnAndARuleIsSentAsCodexOfferedIt() throws {
        var session = Self.readySession()
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        _ = session.receive(line: Self.commandApproval(id: 3), at: Self.start)
        var responseID = try #require(session.pendingResponseIDs.first)
        guard case .submitted(let deny, _) = session.answer(responseID: responseID, answers: [Self.choice("deny")], at: Self.start) else {
            Issue.record("Expected the deny to be taken")
            return
        }
        let denied = try Self.object(deny)
        #expect((denied["result"] as? [String: Any])?["decision"] as? String == "cancel")

        _ = session.receive(line: Self.commandApproval(id: 4), at: Self.start)
        responseID = try #require(session.pendingResponseIDs.first)
        guard case .submitted(let rule, _) = session.answer(responseID: responseID, answers: [Self.choice("always:0")], at: Self.start) else {
            Issue.record("Expected the rule to be taken")
            return
        }
        let ruled = try Self.object(rule)
        let decision = try #require((ruled["result"] as? [String: Any])?["decision"] as? [String: Any])
        let amendment = try #require(decision["acceptWithExecpolicyAmendment"] as? [String: Any])
        #expect(amendment["execpolicy_amendment"] as? [String] == ["touch", "probe-a.txt"])
    }

    @Test func aRequestThatCodexWithdrawsLeavesTheChat() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.receive(line: Self.turnStarted("turn-1"), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.commandApproval(id: 0), at: Self.start), into: &projector)
        #expect(projector.pendingInteractions.count == 1)

        let outputs = session.receive(
            line: #"{"method":"serverRequest/resolved","params":{"threadId":"\#(Self.threadID)","requestId":0}}"#,
            at: Self.start
        )
        Self.ingest(outputs, into: &projector)
        #expect(projector.pendingInteractions.isEmpty)
        #expect(session.waitingRequest == nil)
    }

    @Test func aFileChangeApprovalShowsTheChange() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.receive(line: Self.turnStarted("turn-1"), at: Self.start), into: &projector)
        let approval = #"{"method":"item/fileChange/requestApproval","id":1,"params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","itemId":"patch-1","reason":"needs to write outside the workspace"}}"#

        // Nobody can approve a change that Toastty cannot show.
        let unknown = try Self.requiredObject(Self.written(session.receive(line: approval, at: Self.start)).first)
        #expect((unknown["result"] as? [String: Any])?["decision"] as? String == "decline")

        let item = #"{"method":"item/started","params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","item":{"type":"fileChange","id":"patch-1","status":"inProgress","changes":[{"path":"/work/notes.txt","kind":{"type":"add"},"diff":"+hello"}]}}}"#
        Self.ingest(session.receive(line: item, at: Self.start), into: &projector)
        Self.ingest(session.receive(line: approval, at: Self.start), into: &projector)
        let interaction = try #require(projector.pendingInteractions.first)
        #expect(interaction.permission?.toolName == "File change")
        #expect(interaction.permission?.preview == "add /work/notes.txt\n+hello")
        #expect(interaction.options.map(\.id) == ["allow", "deny"])

        // A move shows where the file goes.
        let move = #"{"method":"item/started","params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","item":{"type":"fileChange","id":"patch-2","status":"inProgress","changes":[{"path":"/work/notes.txt","kind":{"type":"update","move_path":"/Users/me/.zshrc"},"diff":"-a\n+b"}]}}}"#
        _ = session.receive(line: move, at: Self.start)
        let moveApproval = approval.replacingOccurrences(of: "patch-1", with: "patch-2").replacingOccurrences(of: #""id":1"#, with: #""id":2"#)
        Self.ingest(session.receive(line: moveApproval, at: Self.start), into: &projector)
        #expect(projector.pendingInteractions.last?.permission?.preview
            == "update /work/notes.txt (moved to /Users/me/.zshrc)\n-a\n+b")
    }

    @Test func twoRequestsWaitAndEachTakesItsOwnAnswer() throws {
        var session = Self.readySession()
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        _ = session.receive(line: Self.commandApproval(id: 0), at: Self.start)
        _ = session.receive(
            line: Self.commandApproval(id: 1).replacingOccurrences(of: "exec-1", with: "exec-2"),
            at: Self.start
        )
        let responseIDs = session.pendingResponseIDs
        #expect(responseIDs.count == 2)
        // The newer one first: the older one still waits, and the status says so.
        guard case .submitted(let line, _) = session.answer(responseID: responseIDs[1], answers: [Self.choice("allow")], at: Self.start) else {
            Issue.record("Expected the newer request's answer to be taken")
            return
        }
        let answer = try Self.object(line)
        #expect(answer["id"] as? Int == 1)
        #expect(session.waitingRequest?.requestID == responseIDs[0])
        #expect(session.pendingResponseIDs == [responseIDs[0]])
    }

    @Test func aRequestTooLongToShowIsDeclined() throws {
        var session = Self.readySession()
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        let command = String(repeating: "x", count: ClaudePermissionHook.maximumPreviewBytes + 1)
        let request = #"{"method":"item/commandExecution/requestApproval","id":2,"params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","itemId":"exec-2","command":"\#(command)","availableDecisions":["accept","cancel"]}}"#
        let answer = try Self.requiredObject(Self.written(session.receive(line: request, at: Self.start)).first)
        #expect((answer["result"] as? [String: Any])?["decision"] as? String == "decline")
        #expect(session.waitingRequest == nil)
    }

    @Test func aQuestionIsAnsweredWithTheChosenLabels() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.receive(line: Self.turnStarted("turn-1"), at: Self.start), into: &projector)
        let request = #"{"method":"item/tool/requestUserInput","id":"q-1","params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","itemId":"input-1","isBlocking":true,"autoResolutionMs":null,"questions":[{"id":"scope","header":"Scope","question":"Which part first?","isOther":true,"isSecret":false,"options":[{"label":"The driver","description":"Core first"},{"label":"The chat","description":"UI first"}]}]}}"#
        Self.ingest(session.receive(line: request, at: Self.start), into: &projector)
        let interaction = try #require(projector.pendingInteractions.first)
        #expect(interaction.kind == .question)
        let responseID = try #require(interaction.responseID)
        #expect(session.waitingRequest == .init(requestID: responseID, permissionSummary: nil))

        guard case .submitted(let line, _) = session.answer(
            responseID: responseID,
            answers: [.init(questionID: "scope", selectedOptionIDs: ["scope:o1"])],
            at: Self.start
        ) else {
            Issue.record("Expected the answer to be taken")
            return
        }
        let answer = try Self.object(line)
        #expect(answer["id"] as? String == "q-1")
        let answers = try #require((answer["result"] as? [String: Any])?["answers"] as? [String: Any])
        #expect((answers["scope"] as? [String: Any])?["answers"] as? [String] == ["The chat"])
    }

    @Test func aRequestThatToasttyCannotServeStillGetsAnAnswer() throws {
        var session = Self.readySession()
        _ = session.receive(line: Self.turnStarted("turn-1"), at: Self.start)
        // A question with no choices has no form.
        let question = #"{"method":"item/tool/requestUserInput","id":5,"params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","itemId":"input-2","questions":[{"id":"name","header":"Name","question":"What name?","isOther":true,"isSecret":false,"options":null}]}}"#
        let noAnswer = try Self.requiredObject(Self.written(session.receive(line: question, at: Self.start)).first)
        #expect(((noAnswer["result"] as? [String: Any])?["answers"] as? [String: Any])?.isEmpty == true)

        let permissions = #"{"method":"item/permissions/requestApproval","id":6,"params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","itemId":"perm-1","cwd":"/work","reason":null,"permissions":{"network":{"enabled":true}}}}"#
        let granted = try Self.requiredObject(Self.written(session.receive(line: permissions, at: Self.start)).first)
        #expect(((granted["result"] as? [String: Any])?["permissions"] as? [String: Any])?.isEmpty == true)

        let unknown = #"{"method":"item/tool/call","id":8,"params":{"threadId":"\#(Self.threadID)","turnId":"turn-1","callId":"c1","tool":"x","arguments":{}}}"#
        let refused = try Self.requiredObject(Self.written(session.receive(line: unknown, at: Self.start)).first)
        #expect(refused["id"] as? Int == 8)
        #expect(refused["error"] != nil)
        #expect(session.waitingRequest == nil)
    }

    // MARK: - Compaction

    /// Codex's terminal reads `/compact` as a command. The app-server has a
    /// request for it and writes no user message, so the request's answer
    /// is the receipt.
    @Test func theCompactCommandAsksCodexToCompact() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        let line = try Self.requiredObject(session.messageLine(text: " /compact\n", clientRequestID: "m1"))
        #expect(line["method"] as? String == "thread/compact/start")
        let requestID = try #require(line["id"] as? Int)

        var outputs = session.receive(line: Self.result(requestID, "{}"), at: Self.start)
        guard case .transcript(.userMessage(let user))? = Self.transcript(outputs).first?.payload else {
            Issue.record("Expected the command's receipt, got \(outputs)")
            return
        }
        #expect(user.text == "/compact")
        #expect(user.clientRequestID == "m1")
        outputs += session.receive(line: Self.turnStarted("turn-c"), at: Self.start)
        outputs += session.receive(
            line: #"{"method":"item/completed","params":{"threadId":"\#(Self.threadID)","turnId":"turn-c","item":{"type":"contextCompaction","id":"compaction-1"}}}"#,
            at: Self.start
        )
        outputs += session.receive(line: Self.turnCompleted("turn-c", status: "completed"), at: Self.start)
        Self.ingest(outputs, into: &projector)
        #expect(outputs.last == .turnEnded(.init(clientRequestIDs: ["m1"], failed: false, interrupted: false)))
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected an open prompt, got \(projector.inputAvailability)")
            return
        }

        // During a turn the same text is a message for the model.
        _ = session.receive(line: Self.turnStarted("turn-2"), at: Self.start)
        let during = try Self.requiredObject(session.messageLine(text: "/compact", clientRequestID: "m2"))
        #expect(during["method"] as? String == "turn/start")
    }

    // MARK: - Fixture

    static let start = Date(timeIntervalSince1970: 1_795_000_000)
    static let threadID = "01a2234b-8287-7073-baa9-707e6972a2c1"
    static let rolloutPath = "/Users/me/.codex/sessions/2026/11/28/rollout-2026-11-28T09-54-40-\(threadID).jsonl"
    static let settings = CodexAppServerSession.ThreadSettings(directory: "/work")

    static func readySession() -> CodexAppServerSession {
        var session = CodexAppServerSession(settings: settings, identity: "test")
        _ = session.startLines()
        _ = session.receive(line: result(1, "{}"), at: start)
        _ = session.receive(line: accountAnswer(2), at: start)
        let outputs = session.receive(line: threadAnswer(3), at: start)
        precondition(session.phase == .ready, "\(outputs)")
        return session
    }

    static func projector() -> ConversationProjector {
        var projector = ConversationProjector(
            conversationID: RemoteConversationID(),
            provider: .codex,
            bindingID: UUID(),
            at: start.addingTimeInterval(-10)
        )
        projector.setHostReadsTurnState(true)
        return projector
    }

    static func ingest(_ outputs: [DirectSessionOutput], into projector: inout ConversationProjector) {
        ingest(outputs.flatMap { output -> [ProviderTranscriptObservation] in
            guard case .observations(let observations) = output else { return [] }
            return observations
        }, into: &projector)
    }

    static func ingest(_ observations: [ProviderTranscriptObservation], into projector: inout ConversationProjector) {
        for observation in observations {
            projector.ingest(observation)
        }
    }

    static func transcript(_ outputs: [DirectSessionOutput]) -> [ProviderTranscriptObservation] {
        outputs.flatMap { output -> [ProviderTranscriptObservation] in
            guard case .observations(let observations) = output else { return [] }
            return observations.filter {
                if case .transcript = $0.payload { return true }
                return false
            }
        }
    }

    static func written(_ outputs: [DirectSessionOutput]) -> [String] {
        outputs.compactMap { output in
            guard case .write(let line) = output else { return nil }
            return line
        }
    }

    static func object(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// The object of a line that must be there. The line is made before
    /// this call: a macro cannot hold a call that changes the session.
    static func requiredObject(_ line: String?) throws -> [String: Any] {
        try object(#require(line))
    }

    static func choice(_ optionID: String) -> RemoteInteractionAnswer {
        .init(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: [optionID])
    }

    static func result(_ id: Int, _ result: String) -> String {
        #"{"id":\#(id),"result":\#(result)}"#
    }

    static func accountAnswer(_ id: Int) -> String {
        result(id, #"{"account":{"type":"chatgpt","email":"me@example.com","planType":"pro"},"requiresOpenaiAuth":true}"#)
    }

    static func threadAnswer(_ id: Int) -> String {
        result(id, #"{"thread":{"id":"\#(threadID)","sessionId":"\#(threadID)","path":"\#(rolloutPath)","cliVersion":"0.172.0","status":{"type":"idle"},"turns":[]},"model":"gpt-6.2-sol","modelProvider":"openai","reasoningEffort":"high","approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}"#)
    }

    static func turnStarted(_ turnID: String) -> String {
        #"{"method":"turn/started","params":{"threadId":"\#(threadID)","turn":{"id":"\#(turnID)","items":[],"status":"inProgress","error":null}}}"#
    }

    static func turnCompleted(_ turnID: String, status: String) -> String {
        #"{"method":"turn/completed","params":{"threadId":"\#(threadID)","turn":{"id":"\#(turnID)","items":[],"status":"\#(status)","error":null}}}"#
    }

    static func userItem(id: String, clientID: String, text: String) -> String {
        #"{"method":"item/completed","params":{"threadId":"\#(threadID)","turnId":"turn-1","completedAtMs":1795888482085,"item":{"type":"userMessage","id":"\#(id)","clientId":"\#(clientID)","content":[{"type":"text","text":"\#(text)","text_elements":[]}],"startedAtMs":1795888482085,"completedAtMs":1795888482085}}}"#
    }

    static func agentItem(id: String, text: String, phase: String) -> String {
        #"{"method":"item/completed","params":{"threadId":"\#(threadID)","turnId":"turn-1","completedAtMs":1795888483090,"item":{"type":"agentMessage","id":"\#(id)","text":"\#(text)","phase":"\#(phase)","startedAtMs":1795888483006,"completedAtMs":1795888483090}}}"#
    }

    static func commandItem(_ method: String, status: String, exitCode: Int? = nil) -> String {
        #"{"method":"\#(method)","params":{"threadId":"\#(threadID)","turnId":"turn-1","item":{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'touch probe-a.txt'","cwd":"/work","status":"\#(status)","aggregatedOutput":null,"exitCode":\#(exitCode.map(String.init) ?? "null")}}}"#
    }

    static func commandApproval(id: Int) -> String {
        #"{"method":"item/commandExecution/requestApproval","id":\#(id),"params":{"kind":"command","threadId":"\#(threadID)","turnId":"turn-1","itemId":"exec-1","startedAtMs":1795888545643,"command":"/bin/zsh -lc 'touch probe-a.txt'","cwd":"/work","proposedExecpolicyAmendment":["touch","probe-a.txt"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","probe-a.txt"]}},"cancel"]}}"#
    }
}

struct CodexAppServerLaunchTests {
    @Test func aPlannedTerminalLaunchBecomesAnAppServerLaunch() throws {
        let made = try CodexAppServerLaunch.make(
            plannedArguments: [
                "codex", "-c", #"notify=["/bin/sh","/tmp/notify.sh"]"#, "--profile", "toastty-managed",
                "--model", "gpt-6.2-sol", "--config", #"model_reasoning_effort="high""#,
                "--config", "project_doc_max_bytes=131072", "--ask-for-approval", "never", "--sandbox=danger-full-access",
                "--no-alt-screen",
            ],
            managedProfile: ("toastty-managed", ["toastty@toastty", "toastty-user@toastty-user"]),
            baseEnvironment: ["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-base", "HOME": "/Users/me"],
            terminalEnvironment: ["TOASTTY_SOCKET_PATH": "/tmp/socket", "PATH": "/toastty/bin:/usr/bin"],
            plannedEnvironment: ["TOASTTY_SESSION_ID": "session-1", "CODEX_API_KEY": "sk-plan"],
            directory: "/work"
        )
        #expect(made.launch.executablePath == "/usr/bin/env")
        #expect(made.launch.arguments == [
            "codex", "app-server",
            "-c", #"notify=["/bin/sh","/tmp/notify.sh"]"#,
            "-c", #"plugins={"toastty@toastty"={enabled=true},"toastty-user@toastty-user"={enabled=true}}"#,
            "-c", #"model_reasoning_effort="high""#,
            "-c", "project_doc_max_bytes=131072",
        ])
        #expect(made.launch.directory == "/work")
        #expect(made.settings == .init(
            directory: "/work", model: "gpt-6.2-sol", approvalPolicy: "never", sandbox: "danger-full-access"
        ))
        // A key in the environment would be billed in place of the plan.
        #expect(made.launch.environment["OPENAI_API_KEY"] == nil)
        #expect(made.launch.environment["CODEX_API_KEY"] == nil)
        #expect(made.launch.environment["PATH"] == "/toastty/bin:/usr/bin")
        #expect(made.launch.environment["TOASTTY_SESSION_ID"] == "session-1")
        #expect(made.launch.environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] == "1")
    }

    @Test func aPlannedResumeNamesTheConversation() throws {
        let made = try CodexAppServerLaunch.make(
            plannedArguments: [
                "sv", "exec", "--", "codex", "--profile", "toastty-managed",
                "resume", "01a2234b-8287-7073-baa9-707e6972a2c1", "--model", "gpt-6.2-sol", "--yolo",
            ],
            managedProfile: ("toastty-managed", []),
            baseEnvironment: [:], terminalEnvironment: [:], plannedEnvironment: [:],
            directory: "/work"
        )
        #expect(made.launch.arguments == ["sv", "exec", "--", "codex", "app-server"])
        #expect(made.settings == .init(
            directory: "/work",
            resumeThreadID: "01a2234b-8287-7073-baa9-707e6972a2c1",
            model: "gpt-6.2-sol",
            approvalPolicy: "never",
            sandbox: "danger-full-access"
        ))
    }

    @Test func anArgumentWithNoPlaceInASessionWithoutATerminalIsRefused() {
        func make(_ arguments: [String]) throws {
            _ = try CodexAppServerLaunch.make(
                plannedArguments: arguments,
                managedProfile: ("toastty-managed", ["toastty@toastty"]),
                baseEnvironment: [:], terminalEnvironment: [:], plannedEnvironment: [:],
                directory: "/work"
            )
        }
        #expect(throws: CodexAppServerLaunch.LaunchError.unsupportedArgument("--search")) {
            try make(["codex", "--search"])
        }
        // Codex 0.172.0 has no such option any more.
        #expect(throws: CodexAppServerLaunch.LaunchError.unsupportedArgument("--full-auto")) {
            try make(["codex", "--full-auto"])
        }
        // Only the profile file that Toastty wrote is known.
        #expect(throws: CodexAppServerLaunch.LaunchError.unsupportedArgument("--profile work")) {
            try make(["codex", "--profile", "work"])
        }
        #expect(throws: CodexAppServerLaunch.LaunchError.unsupportedArgument(#"the argument "fix the build""#)) {
            try make(["codex", "fix the build"])
        }
        #expect(throws: CodexAppServerLaunch.LaunchError.unsupportedArgument("--model")) {
            try make(["codex", "--model"])
        }
        #expect(throws: CodexAppServerLaunch.LaunchError.unsupportedArgument("OPENAI_API_KEY=…")) {
            try make(["env", "OPENAI_API_KEY=sk-test", "codex"])
        }
        // A shell helper hides the command, and its arguments with it.
        #expect(throws: CodexAppServerLaunch.LaunchError.commandNotFound) {
            try make(["scodex", "--model", "gpt-6.2-sol"])
        }
    }
}
