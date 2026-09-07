import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyCLIKit

struct ClaudeQuestionHookRunnerTests {
    @Test
    func parsesQuestionWithoutNormalizingProviderText() throws {
        let parsed = try #require(ClaudeQuestionHookParser.parse(payload()))
        let question = try #require(parsed.event.questions?.first)
        #expect(question.id == "q0")
        #expect(question.question == "  Which approach?\n")
        #expect(question.options.map(\.id) == ["q0:o0", "q0:o1"])
        #expect(question.options[0].detail == "Fast and small")
        #expect(question.options[0].preview == "  + sample\n")
        #expect(parsed.event.promptID == "prompt-1")
        #expect(parsed.event.providerCallID == nil)
    }

    @Test
    func rejectsUnsupportedQuestionsAndSubagents() throws {
        var unsupported = question()
        unsupported["allowFreeform"] = .bool(false)
        var invalidType = question()
        invalidType["multiSelect"] = .int(1)
        var duplicateLabels = question()
        duplicateLabels["options"] = .array([
            .object(["label": .string("Same")]), .object(["label": .string("Same")]),
        ])
        var unsupportedOption = question()
        unsupportedOption["options"] = .array([
            .object(["label": .string("First"), "value": .string("unsupported")]),
            .object(["label": .string("Second")]),
        ])
        for value in [unsupported, invalidType, duplicateLabels, unsupportedOption] {
            #expect(ClaudeQuestionHookParser.parse(payload(questions: [.object(value)])) == nil)
        }
        #expect(ClaudeQuestionHookParser.parse(payload(questions: [])) == nil)
        #expect(ClaudeQuestionHookParser.parse(payload(questions: Array(repeating: .object(question()), count: 5))) == nil)
        #expect(ClaudeQuestionHookParser.parse(payload(extra: ["agent_id": .string("subagent-1")])) == nil)
        #expect(ClaudeQuestionHookParser.parse(Data(repeating: 32, count: ClaudeQuestionHookParser.maximumPayloadBytes + 1)) == nil)
    }

    @Test
    func observesAuthoritativeDesktopAnswersAndLifecycleWithoutWaiting() throws {
        let answers: [String: AutomationJSONValue] = ["  Which approach?\n": .string("Desktop custom answer")]
        for name in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "SessionEnd"] {
            var sent: [ClaudeQuestionHookRequest] = []
            let runner = ClaudeQuestionHookRunner(send: { request in
                sent.append(request)
                return .init(status: .observed)
            }, sleep: { _ in Issue.record("observation must not wait") })
            let result = runner.run(
                payload: payload(name: name, extra: [
                    "tool_use_id": .string("call-1"),
                    "tool_response": .object(["answers": .object(answers)]),
                ]),
                sessionID: "managed-session",
                panelID: UUID()
            )
            #expect(result.providerResponse == nil)
            #expect(!result.suppressTelemetry)
            #expect(sent.count == 1)
            #expect(sent.first?.phase == .observe)
            if name == "PostToolUse" {
                #expect(sent.first?.event?.answers == ["  Which approach?\n": "Desktop custom answer"])
                #expect(sent.first?.event?.providerCallID == "call-1")
            }
        }
    }

    @Test
    func answerPreservesOriginalInputAndLeavesCompletionToProvider() throws {
        let harness = Harness(replies: [
            .init(status: .pending, responseID: "response-1"),
            .init(status: .answer, responseID: "response-1", answers: [
                .init(questionID: "q0", selectedOptionIDs: ["q0:o1"]),
            ]),
        ])
        let result = harness.runner.run(payload: payload(), sessionID: "managed-session", panelID: harness.panelID)
        #expect(result.suppressTelemetry)
        let json = try #require(result.providerResponse)
        let output = try JSONDecoder().decode([String: AutomationJSONValue].self, from: Data(json.utf8))
        let hook = try #require(output.object("hookSpecificOutput"))
        #expect(hook.string("hookEventName") == "PermissionRequest")
        let decision = try #require(hook.object("decision"))
        #expect(Set(decision.keys) == ["behavior", "updatedInput"])
        #expect(decision.string("behavior") == "allow")
        let updatedInput = try #require(decision.object("updatedInput"))
        #expect(updatedInput.object("answers") == ["  Which approach?\n": .string("Comprehensive")])
        #expect(updatedInput["questions"] == .array([.object(question())]))
        #expect(updatedInput["metadata"] == .object(["source": .string("provider"), "nested": .array([.int(7), .null])]))
        #expect(harness.requests.map(\.phase) == [.begin, .poll])
        #expect(harness.requests.allSatisfy { $0.sessionID == "managed-session" && $0.panelID == harness.panelID })
        #expect(harness.requests[0].responseID == "response-1")
        #expect(harness.requests[1].event == nil)
        #expect(harness.time == 1)
    }

    @Test
    func invalidOrChangedResponseCannotGenerateProviderJSON() {
        for reply in [
            ClaudeQuestionHookReply(status: .answer, responseID: "response-1", answers: [.init(questionID: "q0", selectedOptionIDs: ["invented"])]),
            ClaudeQuestionHookReply(status: .answer, responseID: "different-response", answers: [.init(questionID: "q0", text: "answer")]),
            ClaudeQuestionHookReply(status: .finished, responseID: "response-1"),
        ] {
            let harness = Harness(replies: [.init(status: .pending, responseID: "response-1"), reply])
            let result = harness.runner.run(payload: payload(), sessionID: "managed", panelID: harness.panelID)
            #expect(result.providerResponse == nil)
            #expect(result.suppressTelemetry)
            #expect(harness.requests.last?.phase == .end)
        }
    }

    @Test
    func unavailableUsesExistingTelemetryAndDoesNotWait() {
        let harness = Harness(replies: [.init(status: .unavailable)])
        let result = harness.runner.run(payload: payload(), sessionID: "managed", panelID: harness.panelID)
        #expect(!result.suppressTelemetry)
        #expect(result.providerResponse == nil)
        #expect(harness.requests.map(\.phase) == [.begin])
        #expect(harness.time == 0)
    }

    @Test
    func transportFailureEndsPendingLeaseWithoutResponse() {
        let harness = Harness(replies: [.init(status: .pending, responseID: "response-1")], failPoll: true)
        let result = harness.runner.run(payload: payload(), sessionID: "managed", panelID: harness.panelID)
        #expect(result.suppressTelemetry)
        #expect(result.providerResponse == nil)
        #expect(harness.requests.map(\.phase) == [.begin, .poll, .end])
    }

    @Test
    func timeoutIsBoundedAndEndsPendingLease() {
        let harness = Harness(replies: [.init(status: .pending, responseID: "response-1")])
        let result = harness.runner.run(payload: payload(), sessionID: "managed", panelID: harness.panelID)
        #expect(result.suppressTelemetry)
        #expect(result.providerResponse == nil)
        #expect(harness.time == ClaudeQuestionValidation.maximumWaitSeconds)
        #expect(harness.requests.last?.phase == .end)
        #expect(harness.requests.filter { $0.phase == .poll }.count == 299)
    }

    @Test
    func answerFromLastInTimePollSurvivesReadCrossingDeadline() {
        var time: TimeInterval = 0
        var phases: [ClaudeQuestionHookRequest.Phase] = []
        let runner = ClaudeQuestionHookRunner(send: { request in
            phases.append(request.phase)
            if request.phase == .poll && time == 299 {
                time += 2
                return .init(status: .answer, responseID: "response-1", answers: [
                    .init(questionID: "q0", selectedOptionIDs: ["q0:o0"]),
                ])
            }
            return .init(status: .pending, responseID: "response-1")
        }, makeResponseID: { "response-1" }, uptime: { time }, sleep: { time += $0 })

        let result = runner.run(payload: payload(), sessionID: "managed", panelID: UUID())
        #expect(time == 301)
        #expect(result.providerResponse != nil)
        #expect(result.suppressTelemetry)
        #expect(phases.filter { $0 == .poll }.count == 299)
        #expect(!phases.contains(.end))
    }

    @Test
    func responseModeIsExplicitlyOptedInto() throws {
        let invocation = try ToasttyCLI.parse(arguments: [
            "session", "ingest-agent-event", "--source", "claude-hooks", "--session", "managed", "--respond-to-questions",
        ], environment: [:])
        #expect(invocation.command == .sessionIngestAgentEvent(sessionID: "managed", panelID: nil, source: .claudeHooks, respondToQuestions: true))
    }

    private func question() -> [String: AutomationJSONValue] {
        [
            "question": .string("  Which approach?\n"), "header": .string("Approach"), "multiSelect": .bool(false),
            "options": .array([
                .object(["label": .string("Minimal"), "description": .string("Fast and small"), "preview": .string("  + sample\n")]),
                .object(["label": .string("Comprehensive")]),
            ]),
        ]
    }

    private func payload(
        name: String = "PermissionRequest",
        questions: [AutomationJSONValue]? = nil,
        extra: [String: AutomationJSONValue] = [:]
    ) -> Data {
        var object: [String: AutomationJSONValue] = [
            "hook_event_name": .string(name), "session_id": .string("native-session"),
            "prompt_id": .string("prompt-1"), "transcript_path": .string("/tmp/transcript.jsonl"),
            "tool_name": .string("AskUserQuestion"),
            "tool_input": .object([
                "questions": .array(questions ?? [.object(question())]),
                "metadata": .object(["source": .string("provider"), "nested": .array([.int(7), .null])]),
            ]),
        ]
        object.merge(extra) { _, new in new }
        return try! JSONEncoder().encode(object)
    }

    private final class Harness {
        var requests: [ClaudeQuestionHookRequest] = []
        var replies: [ClaudeQuestionHookReply]
        var time: TimeInterval = 0
        var failPoll: Bool
        let panelID = UUID()

        init(replies: [ClaudeQuestionHookReply], failPoll: Bool = false) {
            self.replies = replies
            self.failPoll = failPoll
        }

        var runner: ClaudeQuestionHookRunner {
            ClaudeQuestionHookRunner(send: { request in
                self.requests.append(request)
                if request.phase == .poll && self.failPoll { throw ToasttyCLIError.runtime("test disconnect") }
                if request.phase == .end { return .init(status: .finished, responseID: request.responseID) }
                return self.replies.count > 1 ? self.replies.removeFirst() : self.replies[0]
            }, makeResponseID: { "response-1" }, uptime: { self.time }, sleep: { self.time += $0 })
        }
    }
}
