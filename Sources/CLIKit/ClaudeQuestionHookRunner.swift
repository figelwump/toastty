import CoreState
import Foundation
import RemoteProtocol

/// Keeps provider input local: the host receives only the supported question
/// shape, and the hook builds updatedInput from its captured original input.
struct ParsedClaudeQuestionHook {
    var event: ClaudeQuestionHookEvent
    var originalToolInput: [String: AutomationJSONValue]?

    func providerResponse(answers: [RemoteInteractionAnswer]) -> String? {
        guard let questions = event.questions,
              let providerAnswers = ClaudeQuestionValidation.providerAnswers(answers, for: questions),
              var updatedInput = originalToolInput else { return nil }
        updatedInput["answers"] = .object(providerAnswers.mapValues(AutomationJSONValue.string))
        let response: [String: AutomationJSONValue] = [
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object([
                    "behavior": .string("allow"),
                    "updatedInput": .object(updatedInput),
                ]),
            ]),
        ]
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum ClaudeQuestionHookParser {
    static let maximumPayloadBytes = 256 * 1024

    static func parse(_ payload: Data) -> ParsedClaudeQuestionHook? {
        guard payload.count <= maximumPayloadBytes,
              let object = try? JSONDecoder().decode([String: AutomationJSONValue].self, from: payload),
              object["agent_id"] == nil,
              let name = object.string("hook_event_name"),
              let eventName = ClaudeQuestionHookEvent.EventName(rawValue: name),
              let nativeSessionID = object.string("session_id"),
              !nativeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let toolInput = object.object("tool_input")
        var questions: [RemoteInteractionQuestion]?
        var answers: [String: String]?
        switch eventName {
        case .preToolUse, .permissionRequest, .postToolUse, .postToolUseFailure:
            guard object.string("tool_name") == "AskUserQuestion" else { return nil }
            if let toolInput { questions = parseQuestions(toolInput["questions"]) }
            if eventName == .preToolUse || eventName == .permissionRequest {
                guard questions != nil else { return nil }
            }
            if eventName != .permissionRequest {
                guard let callID = object.string("tool_use_id"), !callID.isEmpty else { return nil }
            }
            if eventName == .postToolUse,
               let rawAnswers = object.object("tool_response")?.object("answers") {
                var parsed: [String: String] = [:]
                for (key, value) in rawAnswers {
                    guard case .string(let answer) = value else { return nil }
                    parsed[key] = answer
                }
                answers = parsed
            }
        case .userPromptSubmit, .stop, .sessionEnd:
            break
        }
        return ParsedClaudeQuestionHook(
            event: ClaudeQuestionHookEvent(
                eventName: eventName,
                nativeSessionID: nativeSessionID,
                promptID: object.string("prompt_id"),
                transcriptPath: object.string("transcript_path"),
                providerCallID: object.string("tool_use_id"),
                questions: questions,
                answers: answers
            ),
            originalToolInput: toolInput
        )
    }

    private static func parseQuestions(_ value: AutomationJSONValue?) -> [RemoteInteractionQuestion]? {
        guard case .array(let rawQuestions)? = value, (1...4).contains(rawQuestions.count) else { return nil }
        var questions: [RemoteInteractionQuestion] = []
        for (index, rawQuestion) in rawQuestions.enumerated() {
            guard case .object(let question) = rawQuestion,
                  Set(question.keys).isSubset(of: ["question", "header", "options", "multiSelect"]),
                  let text = question.string("question"),
                  let header = question.string("header"),
                  let multiSelect = question.bool("multiSelect"),
                  case .array(let rawOptions)? = question["options"],
                  (2...4).contains(rawOptions.count) else { return nil }
            let questionID = "q\(index)"
            var options: [RemotePendingInteraction.Option] = []
            for (optionIndex, rawOption) in rawOptions.enumerated() {
                guard case .object(let option) = rawOption,
                      Set(option.keys).isSubset(of: ["label", "description", "preview"]),
                      let label = option.string("label"),
                      option["description"] == nil || option.string("description") != nil,
                      option["preview"] == nil || option.string("preview") != nil else { return nil }
                options.append(.init(
                    id: "\(questionID):o\(optionIndex)",
                    label: label,
                    detail: option.string("description"),
                    preview: option.string("preview")
                ))
            }
            questions.append(.init(id: questionID, header: header, question: text, options: options, multiSelect: multiSelect))
        }
        return ClaudeQuestionValidation.validateQuestions(questions) ? questions : nil
    }
}

struct ClaudeQuestionHookRunner {
    struct Result {
        var suppressTelemetry = false
        var providerResponse: String?
    }

    var send: (ClaudeQuestionHookRequest) throws -> ClaudeQuestionHookReply
    var makeResponseID: () -> String = { UUID().uuidString }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func run(payload: Data, sessionID: String, panelID: UUID?) -> Result {
        guard let panelID, let parsed = ClaudeQuestionHookParser.parse(payload) else { return Result() }
        let event = parsed.event
        if event.eventName != .permissionRequest {
            _ = try? send(.init(phase: .observe, sessionID: sessionID, panelID: panelID, event: event))
            return Result()
        }

        let deadline = uptime() + ClaudeQuestionValidation.maximumWaitSeconds
        let responseID = makeResponseID()
        guard let initialReply = try? send(.init(phase: .begin, sessionID: sessionID, panelID: panelID, event: event, responseID: responseID)) else {
            // A disconnected begin may have reached the host before its reply
            // was lost. Close only this hook's generated response identifier.
            _ = try? send(.init(phase: .end, sessionID: sessionID, panelID: panelID, responseID: responseID))
            return Result()
        }
        guard initialReply.status == .pending || initialReply.status == .answer,
              initialReply.responseID == responseID else { return Result() }

        // Once the host presents a structured question, generic permission
        // telemetry would replace it. Keep it suppressed through fallback.
        var delivered = false
        defer {
            if !delivered {
                _ = try? send(.init(phase: .end, sessionID: sessionID, panelID: panelID, responseID: responseID))
            }
        }
        var reply = initialReply
        // Process a reply from an in-time poll even if its socket read crossed
        // the deadline. The deadline limits further polls, not received answers.
        while true {
            guard reply.responseID == responseID else { break }
            switch reply.status {
            case .answer:
                guard let answers = reply.answers,
                      let response = parsed.providerResponse(answers: answers) else {
                    return Result(suppressTelemetry: true)
                }
                // PostToolUse, including a desktop answer winning the race,
                // is the authority that closes the host's pending question.
                delivered = true
                return Result(suppressTelemetry: true, providerResponse: response)
            case .pending:
                sleep(min(ClaudeQuestionValidation.pollIntervalSeconds, max(0, deadline - uptime())))
                guard uptime() < deadline,
                      let next = try? send(.init(phase: .poll, sessionID: sessionID, panelID: panelID, responseID: responseID)) else {
                    return Result(suppressTelemetry: true)
                }
                reply = next
            case .observed, .finished, .unavailable:
                return Result(suppressTelemetry: true)
            }
        }
        return Result(suppressTelemetry: true)
    }

    static func socketTransport(socketPath: String) -> (ClaudeQuestionHookRequest) throws -> ClaudeQuestionHookReply {
        { request in
            let requestData = try JSONEncoder().encode(request)
            guard let requestJSON = String(data: requestData, encoding: .utf8) else {
                throw ToasttyCLIError.runtime("failed to encode Claude question request")
            }
            let response = try ToasttySocketClient(socketPath: socketPath, timeoutInterval: 2).send(
                AutomationRequestEnvelope(
                    requestID: UUID().uuidString,
                    command: "session.claude_question",
                    callerSessionID: request.sessionID,
                    payload: ["requestJSON": .string(requestJSON)]
                )
            )
            guard response.ok, let replyJSON = response.result?.string("replyJSON") else {
                throw ToasttyCLIError.runtime("Claude question hook unavailable")
            }
            return try JSONDecoder().decode(ClaudeQuestionHookReply.self, from: Data(replyJSON.utf8))
        }
    }
}
