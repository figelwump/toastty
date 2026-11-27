import Foundation
import RemoteProtocol
import Testing
@testable import CoreState

/// Drives `ClaudeStreamSession` with the lines that Claude Code 2.1.332
/// wrote in stream-json mode, shortened to the fields that the session
/// reads. A projector with `hostReadsTurnState` takes the observations, as
/// in the app.
struct ClaudeStreamSessionTests {
    // MARK: - The start

    @Test func aStartWithoutAPlanSignInFailsBeforeAnyMessage() {
        // Claude Code in bare mode reads no sign-in: its account has no plan.
        var session = ClaudeStreamSession(at: Self.start)
        _ = session.startRequestLine()
        let outputs = session.receive(
            line: Self.startAnswer(session, account: #"{"tokenSource":"none","apiProvider":"firstParty"}"#),
            at: Self.start
        )
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the start to fail, got \(outputs)")
            return
        }
        #expect(reason.contains("without a Claude plan sign-in"))
        let refused = session.userMessageLine(text: "hello", clientRequestID: "m1")
        #expect(refused == nil)
        let ignored = session.receive(line: Self.systemInit(), at: Self.start)
        #expect(ignored.isEmpty)
    }

    @Test func aStartWithoutTheRequiredSkillFails() {
        var session = ClaudeStreamSession(
            requirements: .init(anyOfCommands: ["toastty:toastty-coordinator", "toastty-coordinator"]),
            at: Self.start
        )
        _ = session.startRequestLine()
        let outputs = session.receive(line: Self.startAnswer(session, commands: ["deep-research"]), at: Self.start)
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the start to fail, got \(outputs)")
            return
        }
        #expect(reason.contains("without Toastty's skills"))

        var withSkill = ClaudeStreamSession(
            requirements: .init(anyOfCommands: ["toastty:toastty-coordinator", "toastty-coordinator"]),
            at: Self.start
        )
        _ = withSkill.startRequestLine()
        let started = withSkill.receive(
            line: Self.startAnswer(withSkill, commands: ["deep-research", "toastty:toastty-coordinator"]),
            at: Self.start
        )
        #expect(started.first == .ready(Self.account))
    }

    @Test func aTurnThatWouldBillAnAPIKeyStopsTheSession() {
        var session = Self.readySession()
        let outputs = session.receive(line: Self.systemInit(apiKeySource: "ANTHROPIC_API_KEY"), at: Self.start)
        guard case .failed(let reason)? = outputs.first else {
            Issue.record("Expected the session to fail, got \(outputs)")
            return
        }
        #expect(reason.contains("ANTHROPIC_API_KEY"))
        #expect(session.phase == .failed(reason))
    }

    // MARK: - Messages and turns

    @Test func aMessageIsConfirmedByItsOwnReceiptAndTheTurnEndOpensThePromptAtOnce() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        guard case .openPrompt(let firstEpoch) = projector.inputAvailability else {
            Issue.record("Expected an open prompt after the start")
            return
        }

        let line = try Self.send("Reply with ONE", id: "msg-1", to: &session)
        let messageID = try Self.messageID(of: line)
        var outputs: [ClaudeStreamSession.Output] = []
        outputs += session.receive(line: Self.systemInit(), at: Self.start)
        #expect(session.isTurnRunning)
        // Another message with the same text is not the receipt.
        outputs += session.receive(line: Self.user("Reply with ONE", uuid: "someone-else", replay: true), at: Self.start)
        outputs += session.receive(line: Self.user("Reply with ONE", uuid: messageID, replay: true), at: Self.start)
        outputs += session.receive(line: Self.assistantText("ONE", uuid: "a1", messageID: "api-1"), at: Self.start)
        outputs += session.receive(
            line: Self.result(answering: [messageID]),
            at: Self.start
        )
        Self.ingest(outputs, into: &projector)

        let users = projector.events.compactMap { event -> ConversationUserMessagePayload? in
            guard case .userMessage(let payload) = event.payload else { return nil }
            return payload
        }
        #expect(users.map(\.clientRequestID) == [nil, "msg-1"])
        #expect(users.last?.origin == .remote)
        #expect(session.isTurnRunning == false)
        // No stabilization window: the prompt is open with the turn's end.
        guard case .openPrompt(let nextEpoch) = projector.inputAvailability else {
            Issue.record("Expected an open prompt after the turn, got \(projector.inputAvailability)")
            return
        }
        #expect(nextEpoch != firstEpoch)
        #expect(projector.pendingPromptStabilizationToken == nil)
        #expect(outputs.contains(.turnEnded(.init(
            clientRequestIDs: ["msg-1"], failed: false, interrupted: false, queuedTurnCount: 0
        ))))
    }

    @Test func assistantTextMatchesTheTranscriptFilesRecord() throws {
        // The stream gives the text before its stop reason. The file's
        // record has it. Both have one fingerprint, so they must agree on
        // whether the text is the turn's final answer.
        var session = Self.readySession()
        var outputs: [ClaudeStreamSession.Output] = []
        outputs += session.receive(line: Self.systemInit(), at: Self.start)
        outputs += session.receive(line: Self.assistantText("I will run it.", uuid: "a1", messageID: "api-1"), at: Self.start)
        outputs += session.receive(line: Self.assistantToolUse(callID: "toolu_1", uuid: "a2", messageID: "api-1"), at: Self.start)
        outputs += session.receive(line: Self.toolResult(callID: "toolu_1", uuid: "u2"), at: Self.start)
        outputs += session.receive(line: Self.assistantText("Done.", uuid: "a3", messageID: "api-2"), at: Self.start)
        // Held until the turn's end says what it is.
        #expect(Self.transcript(outputs).contains { $0.fingerprint == "assistant:a3:0" } == false)
        outputs += session.receive(line: Self.result(answering: []), at: Self.start)

        let file = ClaudeTranscriptParser.parseContents("""
        {"type":"assistant","uuid":"a1","timestamp":"\(Self.stamp)","message":{"id":"api-1","model":"claude-haiku","stop_reason":"tool_use","content":[{"type":"text","text":"I will run it."}]}}
        {"type":"assistant","uuid":"a2","timestamp":"\(Self.stamp)","message":{"id":"api-1","model":"claude-haiku","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"user","uuid":"u2","timestamp":"\(Self.stamp)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}
        {"type":"assistant","uuid":"a3","timestamp":"\(Self.stamp)","message":{"id":"api-2","model":"claude-haiku","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
        """).observations
        let fromFile = Dictionary(uniqueKeysWithValues: file.map { ($0.fingerprint, $0.payload) })
        let fromStream = Self.transcript(outputs)
        #expect(fromStream.map(\.fingerprint) == ["assistant:a1:0", "call:toolu_1", "call_out:toolu_1", "assistant:a3:0"])
        for observation in fromStream {
            #expect(fromFile[observation.fingerprint] == observation.payload, "\(observation.fingerprint)")
            // Content has no say over the prompt: the file may give it first.
            #expect(observation.mayAuthorizeCurrentRuntime == false)
        }
    }

    @Test func anInterruptRequestIsNotAStop() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        let noTurnToStop = session.interruptLine()
        #expect(noTurnToStop == nil)

        let line = try Self.send("Work", id: "msg-1", to: &session)
        Self.ingest(session.receive(line: Self.systemInit(), at: Self.start), into: &projector)
        let interruptLine = session.interruptLine()
        let interrupt = try #require(interruptLine)
        #expect(interrupt.contains(#""subtype":"interrupt""#))
        // The turn runs until Claude reports its end.
        #expect(session.isTurnRunning)
        #expect(session.interruptRequested)
        #expect(projector.state == .working)

        // Claude writes its interrupt marker as a user record. The turn's
        // end is the result, once.
        var outputs = session.receive(line: Self.user("[Request interrupted by user]", uuid: "marker"), at: Self.start)
        outputs += session.receive(
            line: Self.result(subtype: "error_during_execution", answering: [try Self.messageID(of: line)]),
            at: Self.start
        )
        Self.ingest(outputs, into: &projector)
        #expect(outputs.contains(.turnEnded(.init(
            clientRequestIDs: ["msg-1"], failed: false, interrupted: true, queuedTurnCount: 0
        ))))
        let states = projector.events.compactMap { event -> RemoteSessionState? in
            guard case .statusChanged(let payload) = event.payload else { return nil }
            return payload.state
        }
        #expect(states.suffix(2) == [.interrupted, .awaitingInput])
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected an open prompt after the stopped turn")
            return
        }
    }

    @Test func compactionWhileIdleStartsNoWorkAndTheNextMessageStartsOneTurn() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        let first = try Self.send("Earlier work", id: "msg-1", to: &session)
        var outputs = session.receive(line: Self.systemInit(), at: Self.start)
        outputs += session.receive(line: Self.user("Earlier work", uuid: try Self.messageID(of: first), replay: true), at: Self.start)
        outputs += session.receive(line: Self.result(answering: [try Self.messageID(of: first)]), at: Self.start)
        Self.ingest(outputs, into: &projector)

        // Claude compacts. Its summary is a user record that names the
        // earlier work. It is context, not a message.
        outputs = session.receive(line: #"{"type":"system","subtype":"status","status":"compacting"}"#, at: Self.start)
        #expect(session.isCompacting)
        outputs += session.receive(line: #"{"type":"system","subtype":"status","status":null}"#, at: Self.start)
        outputs += session.receive(line: #"{"type":"system","subtype":"compact_boundary","uuid":"boundary"}"#, at: Self.start)
        outputs += session.receive(
            line: Self.user("This session is being continued. Earlier work", uuid: "summary", synthetic: true),
            at: Self.start
        )
        outputs += session.receive(line: Self.result(answering: []), at: Self.start)
        Self.ingest(outputs, into: &projector)
        #expect(session.isTurnRunning == false)
        #expect(session.isCompacting == false)
        guard case .openPrompt = projector.inputAvailability else {
            Issue.record("Expected an open prompt after compaction")
            return
        }
        let turnsBefore = Self.turnEndCount(in: projector)

        let next = try Self.send("New work", id: "msg-2", to: &session)
        outputs = session.receive(line: Self.systemInit(), at: Self.start)
        outputs += session.receive(line: Self.user("New work", uuid: try Self.messageID(of: next), replay: true), at: Self.start)
        outputs += session.receive(line: Self.result(answering: [try Self.messageID(of: next)]), at: Self.start)
        Self.ingest(outputs, into: &projector)
        #expect(Self.turnEndCount(in: projector) == turnsBefore + 1)
        let texts = projector.events.compactMap { event -> String? in
            guard case .userMessage(let payload) = event.payload else { return nil }
            return payload.text
        }
        #expect(texts == ["Earlier work", "New work"])
    }

    @Test func aResultWithNoSignOfATurnStillOpensThePromptAgain() throws {
        // `/context` is answered by Claude Code itself. The message used
        // the prompt, so the result must open a new one.
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        guard case .openPrompt(let before) = projector.inputAvailability else {
            Issue.record("Expected an open prompt")
            return
        }
        Self.ingest(session.receive(line: Self.result(answering: []), at: Self.start), into: &projector)
        guard case .openPrompt(let after) = projector.inputAvailability else {
            Issue.record("Expected an open prompt")
            return
        }
        #expect(after != before)
    }

    @Test func recordsFromBeforeTheStartAndFromSubagentsStartNoTurn() {
        var session = Self.readySession()
        // A resumed process can write earlier records again.
        var outputs = session.receive(
            line: Self.user("Old message", uuid: "old", timestamp: "2026-11-01T00:00:00.000Z"),
            at: Self.start
        )
        #expect(session.isTurnRunning == false)
        #expect(Self.transcript(outputs).map(\.fingerprint) == ["user:old"])
        // A background subagent writes while no root turn runs.
        outputs = session.receive(
            line: #"{"type":"assistant","uuid":"sub","parent_tool_use_id":"toolu_agent","timestamp":"\#(Self.stamp)","message":{"id":"api-s","content":[{"type":"text","text":"subagent"}]}}"#,
            at: Self.start
        )
        #expect(session.isTurnRunning == false)
        #expect(outputs.isEmpty)
    }

    // MARK: - Requests

    @Test func aPermissionRequestTakesTheFirstAnswerOnly() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.systemInit(), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.permissionRequest(requestID: "req-1", callID: "toolu_1"), at: Self.start), into: &projector)

        let interaction = try #require(projector.pendingInteractions.first)
        #expect(interaction.kind == .permission)
        #expect(interaction.responseID == "req-1")
        #expect(interaction.permission?.toolName == "Bash")
        // An argument that the formatted preview does not show is listed
        // above it, so nobody approves a command they cannot read in full.
        #expect(interaction.permission?.preview.hasSuffix("git push origin main") == true)
        #expect(interaction.permission?.preview.contains("timeout") == true)
        #expect(interaction.questions?.first?.options.map(\.label) == [
            "Allow once", "Always allow Bash(git push origin main)", "Deny",
        ])
        #expect(projector.state == .awaitingInput)

        // The phone allows; the Mac's deny comes second.
        let allow = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["allow"])]
        let deny = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["deny"])]
        guard case .submitted(let line, let observations) = session.answer(responseID: "req-1", answers: allow, at: Self.start) else {
            Issue.record("Expected the first answer to be submitted")
            return
        }
        let second = session.answer(responseID: "req-1", answers: deny, at: Self.start)
        #expect(second == .notPending)
        let response = try Self.object(line)
        let body = try #require((response["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect((response["response"] as? [String: Any])?["request_id"] as? String == "req-1")
        #expect(body["behavior"] as? String == "allow")
        // The tool input goes back as Claude sent it.
        #expect((body["updatedInput"] as? [String: Any])?["command"] as? String == "git push origin main")
        #expect((body["updatedInput"] as? [String: Any])?["timeout"] as? Int == 120_000)

        Self.ingest(observations, into: &projector)
        #expect(projector.pendingInteractions.isEmpty)
        #expect(projector.state == .working)
    }

    @Test func denyStopsTheTurnAndAlwaysAllowCarriesClaudesOwnRule() throws {
        var session = Self.readySession()
        _ = session.receive(line: Self.systemInit(), at: Self.start)
        _ = session.receive(line: Self.permissionRequest(requestID: "req-1", callID: "toolu_1"), at: Self.start)
        let deny = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["deny"])]
        guard case .submitted(let denyLine, _) = session.answer(responseID: "req-1", answers: deny, at: Self.start) else {
            Issue.record("Expected the deny to be submitted")
            return
        }
        let denied = try #require((try Self.object(denyLine)["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(denied["behavior"] as? String == "deny")
        #expect(denied["interrupt"] as? Bool == true)
        #expect(denied["updatedInput"] == nil)

        _ = session.receive(line: Self.permissionRequest(requestID: "req-2", callID: "toolu_2"), at: Self.start)
        let always = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["always:0"])]
        guard case .submitted(let alwaysLine, _) = session.answer(responseID: "req-2", answers: always, at: Self.start) else {
            Issue.record("Expected the always-allow to be submitted")
            return
        }
        let allowed = try #require((try Self.object(alwaysLine)["response"] as? [String: Any])?["response"] as? [String: Any])
        let rule = try #require((allowed["updatedPermissions"] as? [[String: Any]])?.first)
        #expect(rule["destination"] as? String == "localSettings")

        // An answer that names no offered option changes nothing.
        _ = session.receive(line: Self.permissionRequest(requestID: "req-3", callID: "toolu_3"), at: Self.start)
        let unknown = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["always:7"])]
        let invalid = session.answer(responseID: "req-3", answers: unknown, at: Self.start)
        #expect(invalid == .invalid)
        #expect(session.pendingResponseIDs == ["req-3"])
    }

    @Test func aQuestionIsAnsweredWithTheChosenLabels() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.systemInit(), at: Self.start), into: &projector)
        let request = #"{"type":"control_request","request_id":"req-q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","requires_user_interaction":true,"input":{"questions":[{"question":"Which color?","header":"Color","multiSelect":false,"options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}]}]}}}"#
        Self.ingest(session.receive(line: request, at: Self.start), into: &projector)
        let interaction = try #require(projector.pendingInteractions.first)
        #expect(interaction.kind == .question)
        #expect(interaction.prompt == "Which color?")
        let answers = [RemoteInteractionAnswer(questionID: "q0", selectedOptionIDs: ["q0:o1"])]
        guard case .submitted(let line, let observations) = session.answer(responseID: "req-q", answers: answers, at: Self.start) else {
            Issue.record("Expected the answer to be submitted")
            return
        }
        let body = try #require((try Self.object(line)["response"] as? [String: Any])?["response"] as? [String: Any])
        let input = try #require(body["updatedInput"] as? [String: Any])
        #expect((input["answers"] as? [String: String]) == ["Which color?": "Blue"])
        #expect((input["questions"] as? [[String: Any]])?.count == 1)
        Self.ingest(observations, into: &projector)
        #expect(projector.pendingInteractions.isEmpty)
    }

    @Test func oneRequestWaitsForEachToolCallAndAWithdrawnOneCloses() throws {
        var session = Self.readySession()
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.systemInit(), at: Self.start), into: &projector)
        // Claude asks twice for one tool call. One approval shows.
        Self.ingest(session.receive(line: Self.permissionRequest(requestID: "req-1", callID: "toolu_1"), at: Self.start), into: &projector)
        Self.ingest(session.receive(line: Self.permissionRequest(requestID: "req-2", callID: "toolu_1"), at: Self.start), into: &projector)
        #expect(projector.pendingInteractions.count == 1)
        #expect(projector.pendingInteractions.first?.responseID == "req-2")
        #expect(session.pendingResponseIDs == ["req-2"])
        let allow = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["allow"])]
        let replaced = session.answer(responseID: "req-1", answers: allow, at: Self.start)
        #expect(replaced == .notPending)

        // Claude withdraws the request.
        Self.ingest(
            session.receive(line: #"{"type":"control_cancel_request","request_id":"req-2"}"#, at: Self.start),
            into: &projector
        )
        #expect(projector.pendingInteractions.isEmpty)
        let withdrawn = session.answer(responseID: "req-2", answers: allow, at: Self.start)
        #expect(withdrawn == .notPending)

        // A request that this host cannot serve gets an error, not silence.
        let outputs = session.receive(
            line: #"{"type":"control_request","request_id":"req-x","request":{"subtype":"mcp_message"}}"#,
            at: Self.start
        )
        guard case .write(let line)? = outputs.first else {
            Issue.record("Expected an error response, got \(outputs)")
            return
        }
        #expect((try Self.object(line)["response"] as? [String: Any])?["subtype"] as? String == "error")
    }

    @Test func aRequestThatNobodyCanReadOrAnswerIsDenied() throws {
        var session = Self.readySession()
        _ = session.receive(line: Self.systemInit(), at: Self.start)
        func deniedWithoutAsking(_ request: String) throws -> Bool {
            let outputs = session.receive(line: request, at: Self.start)
            guard case .write(let line)? = outputs.first, outputs.count == 1 else { return false }
            let body = try #require((try Self.object(line)["response"] as? [String: Any])?["response"] as? [String: Any])
            return body["behavior"] as? String == "deny" && session.pendingResponseIDs.isEmpty
        }
        // A command too long to show in full: no terminal shows the rest,
        // so an Allow would approve text that nobody read.
        let longCommand = String(repeating: "a", count: ClaudePermissionHook.maximumPreviewBytes + 1)
        #expect(try deniedWithoutAsking(
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"t1","input":{"command":"\#(longCommand)"}}}"#
        ))
        // A question in a shape that the answer form cannot show.
        #expect(try deniedWithoutAsking(
            #"{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"t2","requires_user_interaction":true,"input":{"questions":[{"question":"Q?","header":"H","multiSelect":false,"options":[{"label":"Only one"}]}]}}}"#
        ))
        // A tool that needs a form of its own.
        #expect(try deniedWithoutAsking(
            #"{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"mcp__forms__collect","tool_use_id":"t3","requires_user_interaction":true,"input":{"fields":["name"]}}}"#
        ))
        // A plan needs the user, and Allow is the approval of the plan.
        let plan = session.receive(
            line: #"{"type":"control_request","request_id":"r4","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","tool_use_id":"t4","requires_user_interaction":true,"input":{"plan":"1. Do it."}}}"#,
            at: Self.start
        )
        #expect(session.pendingResponseIDs == ["r4"])
        #expect(Self.transcript(plan).isEmpty)
    }

    @Test func aTurnThatEndsWithAnErrorThatNobodyAskedForFailed() throws {
        var session = Self.readySession()
        _ = try Self.send("Work", id: "msg-1", to: &session)
        _ = session.receive(line: Self.systemInit(), at: Self.start)
        // Claude Code could not set the turn up. Nobody stopped it.
        let outputs = session.receive(line: Self.result(subtype: "error_during_execution", answering: []), at: Self.start)
        #expect(outputs.contains(.turnEnded(.init(
            clientRequestIDs: [], failed: true, interrupted: false, queuedTurnCount: 0
        ))))

        // A deny tells Claude to stop: that end is the user's, not a failure.
        _ = session.receive(line: Self.systemInit(), at: Self.start)
        _ = session.receive(line: Self.permissionRequest(requestID: "req-1", callID: "toolu_1"), at: Self.start)
        let deny = [RemoteInteractionAnswer(questionID: ClaudePermissionDecision.questionID, selectedOptionIDs: ["deny"])]
        _ = session.answer(responseID: "req-1", answers: deny, at: Self.start)
        let denied = session.receive(line: Self.result(subtype: "error_during_execution", answering: []), at: Self.start)
        #expect(denied.contains(.turnEnded(.init(
            clientRequestIDs: [], failed: false, interrupted: true, queuedTurnCount: 0
        ))))
    }

    @Test func aProjectionThatStartsLateGetsTheStateNow() throws {
        var session = ClaudeStreamSession(at: Self.start)
        let beforeTheStart = session.currentStateObservations(at: Self.start)
        #expect(beforeTheStart.isEmpty)
        session = Self.readySession()
        _ = session.receive(line: Self.systemInit(), at: Self.start)
        _ = session.receive(line: Self.permissionRequest(requestID: "req-1", callID: "toolu_1"), at: Self.start)

        // The projection was built again while a request waits.
        var projector = Self.projector()
        Self.ingest(session.currentStateObservations(at: Self.start), into: &projector)
        #expect(projector.pendingInteractions.first?.responseID == "req-1")
        #expect(projector.state == .awaitingInput)
    }

    // MARK: - Fixture

    static let start = Date(timeIntervalSince1970: 1_795_000_000)
    static let stamp = "2026-11-20T10:00:00.000Z"
    static let account = ClaudeStreamSession.Account(
        subscriptionType: "Claude Max",
        apiProvider: "firstParty",
        claudeCodeVersion: "2.1.332",
        permissionMode: "default"
    )

    static func readySession() -> ClaudeStreamSession {
        var session = ClaudeStreamSession(identity: "test", at: start)
        _ = session.startRequestLine()
        let outputs = session.receive(line: startAnswer(session), at: start)
        precondition(outputs.first == .ready(account))
        return session
    }

    static func projector() -> ConversationProjector {
        var projector = ConversationProjector(
            conversationID: RemoteConversationID(),
            provider: .claude,
            bindingID: UUID(),
            at: start.addingTimeInterval(-10)
        )
        projector.setHostReadsTurnState(true)
        return projector
    }

    static func ingest(_ outputs: [ClaudeStreamSession.Output], into projector: inout ConversationProjector) {
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

    static func transcript(_ outputs: [ClaudeStreamSession.Output]) -> [ProviderTranscriptObservation] {
        outputs.flatMap { output -> [ProviderTranscriptObservation] in
            guard case .observations(let observations) = output else { return [] }
            return observations.filter {
                if case .transcript = $0.payload { return true }
                return false
            }
        }
    }

    static func turnEndCount(in projector: ConversationProjector) -> Int {
        projector.events.filter { event in
            guard case .statusChanged(let payload) = event.payload,
                  case .openPrompt = payload.inputAvailability else { return false }
            return true
        }.count
    }

    /// The line of one message of the host.
    static func send(_ text: String, id: String, to session: inout ClaudeStreamSession) throws -> String {
        let line = session.userMessageLine(text: text, clientRequestID: id)
        return try #require(line)
    }

    static func object(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    static func messageID(of line: String) throws -> String {
        try #require(object(line)["uuid"] as? String)
    }

    static func startAnswer(
        _ session: ClaudeStreamSession,
        account: String = #"{"subscriptionType":"Claude Max","apiProvider":"firstParty"}"#,
        commands: [String] = []
    ) -> String {
        let commandList = commands.map { #"{"name":"\#($0)","description":""}"# }.joined(separator: ",")
        return #"{"type":"control_response","response":{"subtype":"success","request_id":"toastty-start-test","response":{"account":\#(account),"claude_code_version":"2.1.332","current_permission_mode":"default","commands":[\#(commandList)]}}}"#
            .replacingOccurrences(of: "toastty-start-test", with: startRequestID(session))
    }

    /// The ID of the start request that `session` wrote.
    static func startRequestID(_ session: ClaudeStreamSession) -> String {
        var copy = session
        let line = copy.startRequestLine()
        return (try? object(line))?["request_id"] as? String ?? ""
    }

    static func systemInit(apiKeySource: String = "none") -> String {
        #"{"type":"system","subtype":"init","session_id":"native-1","model":"claude-haiku","permissionMode":"default","apiKeySource":"\#(apiKeySource)"}"#
    }

    static func user(
        _ text: String,
        uuid: String,
        replay: Bool = false,
        synthetic: Bool = false,
        timestamp: String = stamp
    ) -> String {
        #"{"type":"user","uuid":"\#(uuid)","session_id":"native-1","parent_tool_use_id":null,"timestamp":"\#(timestamp)","isReplay":\#(replay),"isSynthetic":\#(synthetic),"message":{"role":"user","content":"\#(text)"}}"#
    }

    static func assistantText(_ text: String, uuid: String, messageID: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","session_id":"native-1","parent_tool_use_id":null,"timestamp":"\#(stamp)","message":{"id":"\#(messageID)","model":"claude-haiku","stop_reason":null,"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    static func assistantToolUse(callID: String, uuid: String, messageID: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","session_id":"native-1","parent_tool_use_id":null,"timestamp":"\#(stamp)","message":{"id":"\#(messageID)","model":"claude-haiku","stop_reason":null,"content":[{"type":"tool_use","id":"\#(callID)","name":"Bash","input":{"command":"ls"}}]}}"#
    }

    static func toolResult(callID: String, uuid: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","session_id":"native-1","parent_tool_use_id":null,"timestamp":"\#(stamp)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(callID)","content":"ok"}]}}"#
    }

    static func result(subtype: String = "success", answering messageIDs: [String]) -> String {
        let ids = messageIDs.map { #""\#($0)""# }.joined(separator: ",")
        return #"{"type":"result","subtype":"\#(subtype)","is_error":\#(subtype != "success"),"stop_reason":"end_turn","user_message_uuids":[\#(ids)],"queued_turn_count":0}"#
    }

    static func permissionRequest(requestID: String, callID: String) -> String {
        #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","tool_use_id":"\#(callID)","decision_reason":"This command requires approval","input":{"command":"git push origin main","timeout":120000},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push origin main"}],"behavior":"allow","destination":"localSettings"}]}}"#
    }
}

struct ClaudeStreamLaunchTests {
    @Test func theStreamArgumentsFollowTheClaudeCommandOfThePlan() throws {
        let launch = try ClaudeStreamLaunch.make(
            plannedArguments: ["claude", "--settings", "/tmp/s.json", "--plugin-dir", "/tmp/p", "--model", "opus"],
            resumeNativeSessionID: nil,
            baseEnvironment: ["HOME": "/Users/me", "PATH": "/usr/bin"],
            terminalEnvironment: ["PATH": "/shims:/opt/bin", "TOASTTY_SOCKET_PATH": "/tmp/t.sock"],
            plannedEnvironment: ["TOASTTY_SESSION_ID": "s1"],
            directory: "/tmp/coordinator"
        )
        #expect(launch.executablePath == "/usr/bin/env")
        #expect(launch.arguments == ["claude"] + ClaudeStreamLaunch.streamArguments
            + ["--settings", "/tmp/s.json", "--plugin-dir", "/tmp/p", "--model", "opus"])
        #expect(launch.directory == "/tmp/coordinator")
        // The terminal's PATH and the plan's values win over the app's.
        #expect(launch.environment["PATH"] == "/shims:/opt/bin")
        #expect(launch.environment["TOASTTY_SESSION_ID"] == "s1")
        #expect(launch.environment["HOME"] == "/Users/me")
        // The command is found on PATH, past Toastty's own launcher.
        #expect(launch.environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] == "1")
    }

    @Test func aResumeNamesTheConversationAndAWrapperKeepsItsPlace() throws {
        let launch = try ClaudeStreamLaunch.make(
            plannedArguments: ["sv", "exec", "--", "claude", "--model", "opus"],
            resumeNativeSessionID: "native-1",
            baseEnvironment: [:],
            terminalEnvironment: [:],
            plannedEnvironment: [:],
            directory: "/tmp"
        )
        #expect(launch.arguments == ["sv", "exec", "--", "claude"] + ClaudeStreamLaunch.streamArguments
            + ["--resume", "native-1", "--model", "opus"])
    }

    @Test func aPlanThatAlreadyResumesIsNotGivenASecondResume() throws {
        let launch = try ClaudeStreamLaunch.make(
            plannedArguments: ["claude", "--resume", "native-1", "--model", "opus"],
            resumeNativeSessionID: "native-1",
            baseEnvironment: [:],
            terminalEnvironment: [:],
            plannedEnvironment: [:],
            directory: "/tmp"
        )
        #expect(launch.arguments == ["claude"] + ClaudeStreamLaunch.streamArguments
            + ["--resume", "native-1", "--model", "opus"])
        // A plan that names another conversation is refused.
        #expect(throws: ClaudeStreamLaunch.LaunchError.unsupportedArgument("--resume")) {
            try ClaudeStreamLaunch.make(
                plannedArguments: ["claude", "--resume", "native-2"],
                resumeNativeSessionID: "native-1",
                baseEnvironment: [:],
                terminalEnvironment: [:],
                plannedEnvironment: [:],
                directory: "/tmp"
            )
        }
    }

    @Test func aWrapperThatSetsAnAPIKeyForTheCommandIsRefused() {
        #expect(throws: ClaudeStreamLaunch.LaunchError.unsupportedArgument("ANTHROPIC_API_KEY=…")) {
            try ClaudeStreamLaunch.make(
                plannedArguments: ["env", "ANTHROPIC_API_KEY=k1", "claude"],
                resumeNativeSessionID: nil,
                baseEnvironment: [:],
                terminalEnvironment: [:],
                plannedEnvironment: [:],
                directory: "/tmp"
            )
        }
    }

    @Test func noAPIKeyAndNoOuterClaudeSessionReachTheProcess() throws {
        let launch = try ClaudeStreamLaunch.make(
            plannedArguments: ["claude"],
            resumeNativeSessionID: nil,
            baseEnvironment: ["ANTHROPIC_API_KEY": "k1", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "outer", "KEEP": "1"],
            terminalEnvironment: ["ANTHROPIC_AUTH_TOKEN": "k2"],
            plannedEnvironment: ["ANTHROPIC_API_KEY": "k3"],
            directory: "/tmp"
        )
        #expect(launch.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(launch.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(launch.environment["CLAUDECODE"] == nil)
        #expect(launch.environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(launch.environment["KEEP"] == "1")
    }

    @Test(arguments: ["--bare", "--print", "--output-format=json", "--resume", "--session-id"])
    func aProfileArgumentThatTheSessionCannotKeepIsRefused(argument: String) {
        #expect(throws: ClaudeStreamLaunch.LaunchError.unsupportedArgument(
            argument.split(separator: "=").first.map(String.init) ?? argument
        )) {
            try ClaudeStreamLaunch.make(
                plannedArguments: ["claude", "--model", "opus", argument],
                resumeNativeSessionID: nil,
                baseEnvironment: [:],
                terminalEnvironment: [:],
                plannedEnvironment: [:],
                directory: "/tmp"
            )
        }
    }
}

struct ClaudeStreamProcessTests {
    /// A stand-in for Claude Code: it answers each line with one line, so
    /// the test sees both directions, a line split over two writes, the
    /// error output and the exit.
    @Test func linesGoBothWaysAndTheExitComesLast() async throws {
        let script = """
        printf '{"type":"hel'; sleep 0.05; printf 'lo"}\\n'
        while IFS= read -r line; do printf 'got:%s\\n' "$line"; done
        echo 'bye' >&2
        exit 3
        """
        let events = Events()
        let process = ClaudeStreamProcess(
            launch: ClaudeStreamLaunch(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                environment: ["PATH": "/usr/bin:/bin"],
                directory: NSTemporaryDirectory()
            )
        ) { events.append($0) }
        try process.start()
        #expect(process.processIdentifier != nil)
        #expect(process.write(line: #"{"type":"user"}"#))
        #expect(process.write(line: "second"))
        try await events.wait { $0.count >= 3 }
        process.terminate(gracePeriod: 5)
        try await events.wait { $0.last?.isExit == true }
        #expect(events.all == [
            .line(#"{"type":"hello"}"#),
            .line(#"got:{"type":"user"}"#),
            .line("got:second"),
            .exited(status: 3, errorOutput: "bye\n"),
        ])
        #expect(process.write(line: "late") == false)
        #expect(process.processIdentifier == nil)
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ClaudeStreamProcess.Event] = []

        var all: [ClaudeStreamProcess.Event] { lock.withLock { events } }

        func append(_ event: ClaudeStreamProcess.Event) {
            lock.withLock { events.append(event) }
        }

        func wait(_ condition: ([ClaudeStreamProcess.Event]) -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while condition(all) == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out; events: \(all)")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

private extension ClaudeStreamProcess.Event {
    var isExit: Bool {
        if case .exited = self { return true }
        return false
    }
}
