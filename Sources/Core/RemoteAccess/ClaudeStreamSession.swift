import Foundation
import RemoteProtocol

/// One conversation with a Claude Code process that the host runs itself, in
/// print mode with stream-json input and output
/// (`claude -p --input-format stream-json --output-format stream-json`).
///
/// The process and the host exchange one JSON object for each line. This
/// value makes each line that the host writes, and turns each line that the
/// process writes into conversation observations and a known state: whether
/// a turn runs, which requests wait for an answer, and which of the host's
/// messages Claude took. It does no input or output itself, so a test can
/// drive it with recorded lines.
///
/// What it reports, and why the host can rely on it:
/// - **A message's receipt.** The host gives each message its own `uuid`.
///   Claude writes the message back with that `uuid` when it takes it
///   (`--replay-user-messages`), so a receipt names its message exactly.
/// - **A turn's end.** Claude writes one `result` for each turn. Until then
///   the turn runs, also after an interrupt request, which is a request and
///   not a stop.
/// - **A request for permission or an answer.** Claude asks with a
///   `can_use_tool` request and waits for the response. Each request takes
///   one response: the first valid answer.
///
/// Message content is not lifecycle here. The transcript rows come from the
/// same parser as the transcript file's, with the file's fingerprints, and
/// carry no authority over the prompt: a projection can read the file for
/// the history and this stream for what happens now, in any order. The
/// turn's start and end and each request are separate observations that
/// only this value makes.
public struct ClaudeStreamSession: Sendable {
    /// What must hold before the first message goes to the process.
    public struct Requirements: Equatable, Sendable {
        /// The process must use the user's Claude plan sign-in. Without
        /// this check, a Claude Code that reads no sign-in (`--bare`, which
        /// a later release makes the default of `-p`) would bill an API key
        /// when the environment has one.
        public var requiresPlanSignIn: Bool
        /// The process must offer at least one of these commands, such as
        /// the name of a skill that the host delivers. Empty checks nothing.
        public var anyOfCommands: [String]

        public init(requiresPlanSignIn: Bool = true, anyOfCommands: [String] = []) {
            self.requiresPlanSignIn = requiresPlanSignIn
            self.anyOfCommands = anyOfCommands
        }
    }

    /// What the process said about itself in its answer to the start request.
    public struct Account: Equatable, Sendable {
        /// The plan's name, such as "Claude Max". `nil` when the process
        /// uses no plan sign-in.
        public var subscriptionType: String?
        public var apiProvider: String?
        public var claudeCodeVersion: String?
        public var permissionMode: String?
    }

    public enum Phase: Equatable, Sendable {
        /// The process runs. Its answer to the start request has not come.
        case starting
        /// It takes messages.
        case ready
        /// It must get no message. The host stops the process.
        case failed(String)
    }

    /// The end of one turn, from Claude's `result`.
    public struct TurnEnd: Equatable, Sendable {
        /// The host's IDs of the messages that this turn answered.
        public var clientRequestIDs: [String]
        /// The turn ended with an error, and no interrupt caused it.
        public var failed: Bool
        /// An interrupt or a denied request ended the turn.
        public var interrupted: Bool
        /// Messages that Claude already holds for turns that follow. Each
        /// starts its turn without a new message from the host.
        public var queuedTurnCount: Int
    }

    public enum Output: Equatable, Sendable {
        case observations([ProviderTranscriptObservation])
        /// The start request was answered and the requirements hold.
        case ready(Account)
        case turnEnded(TurnEnd)
        /// A line that the host must write to the process now.
        case write(String)
        /// The session must stop; see `Phase.failed`.
        case failed(String)
    }

    public enum AnswerOutcome: Equatable, Sendable {
        /// Write `line`, then ingest `observations`.
        case submitted(line: String, observations: [ProviderTranscriptObservation])
        /// No request with this ID waits: it was answered or withdrawn.
        case notPending
        /// The answers do not fit the request.
        case invalid
    }

    public private(set) var phase: Phase = .starting
    public private(set) var account: Account?
    /// Claude's own ID of the conversation, from its first turn.
    public private(set) var nativeSessionID: String?
    public private(set) var isTurnRunning = false
    public private(set) var isCompacting = false
    /// The host asked to stop the running turn. The turn runs until its
    /// `result`.
    public private(set) var interruptRequested = false
    /// The host denied a request of the running turn. A deny tells Claude
    /// to stop, so the turn's end is the user's stop, not a failure.
    private var deniedRequestInTurn = false

    private let requirements: Requirements
    /// Names this process in fingerprints, so the lifecycle observations of
    /// a later process of the same conversation are new ones.
    private let identity: String
    /// A message with an earlier time is history that a resumed process
    /// can write again. It never starts a turn.
    private let startedAt: Date
    private var startRequestID: String?
    private var lifecycleCounter = 0
    private var parser = ClaudeTranscriptParser()
    private var sentMessages: [String: SentMessage] = [:]
    private var sentMessageOrder: [String] = []
    private var pendingRequests: [PendingRequest] = []
    /// Assistant text whose place in the turn is not known yet; see
    /// `flushHeldText`.
    private var heldText: [ProviderTranscriptObservation] = []
    private var heldTextMessageID: String?

    private static let rememberedSentMessages = 256

    private struct SentMessage: Equatable, Sendable {
        var clientRequestID: String
        var deliveryMode: RemoteMessageDeliveryMode
    }

    private struct PendingRequest: Equatable, Sendable {
        enum Form: Equatable, Sendable {
            case question([RemoteInteractionQuestion])
            case permission(ClaudePermissionHook)
        }

        var requestID: String
        var toolUseID: String
        var toolName: String
        /// The tool input exactly as Claude sent it. An allow sends it back.
        var inputJSON: Data
        var form: Form
        var prompt: String
        var presentedAt: Date
    }

    public init(requirements: Requirements = Requirements(), identity: String = UUID().uuidString, at date: Date) {
        self.requirements = requirements
        self.identity = identity
        self.startedAt = date
    }

    /// The IDs of the requests that wait for an answer, oldest first.
    public var pendingResponseIDs: [String] {
        pendingRequests.map(\.requestID)
    }

    /// A request that waits for the user's answer, as the session's status
    /// names it.
    public struct WaitingRequest: Equatable, Sendable {
        public var requestID: String
        /// What a permission request asks for. `nil` for a question.
        public var permissionSummary: String?
    }

    /// The oldest request that waits for an answer, or `nil` when none
    /// waits. The session knows the moment a request starts to wait and
    /// the moment it has its answer; no hook reports the second.
    public var waitingRequest: WaitingRequest? {
        pendingRequests.first.map { request in
            switch request.form {
            case .question:
                WaitingRequest(requestID: request.requestID, permissionSummary: nil)
            case .permission:
                WaitingRequest(requestID: request.requestID, permissionSummary: request.prompt)
            }
        }
    }

    // MARK: - Lines the host writes

    /// The first line the host writes. The process answers with its account
    /// and its commands before it gets any message, so the requirements are
    /// checked before a message can cost anything.
    public mutating func startRequestLine() -> String {
        let requestID = "toastty-start-\(identity)"
        startRequestID = requestID
        return Self.line([
            "type": "control_request",
            "request_id": requestID,
            "request": ["subtype": "initialize", "hooks": NSNull()] as [String: Any],
        ])
    }

    /// The line for one message of the host, or `nil` while the session
    /// takes none. `clientRequestID` comes back on the transcript's user
    /// message when Claude takes this message. A `steer` goes into the
    /// running turn; Claude reads it after the tool call that runs.
    public mutating func userMessageLine(
        text: String,
        clientRequestID: String,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) -> String? {
        guard phase == .ready else { return nil }
        let messageID = UUID().uuidString.lowercased()
        sentMessages[messageID] = SentMessage(clientRequestID: clientRequestID, deliveryMode: deliveryMode)
        sentMessageOrder.append(messageID)
        if sentMessageOrder.count > Self.rememberedSentMessages {
            sentMessages.removeValue(forKey: sentMessageOrder.removeFirst())
        }
        return Self.line([
            "type": "user",
            "uuid": messageID,
            "session_id": nativeSessionID ?? "",
            "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": text],
        ] as [String: Any])
    }

    /// The line that asks Claude to stop the running turn, or `nil` when no
    /// turn runs. The turn ends with its `result`, not with this request.
    public mutating func interruptLine() -> String? {
        guard phase == .ready, isTurnRunning else { return nil }
        interruptRequested = true
        lifecycleCounter += 1
        return Self.line([
            "type": "control_request",
            "request_id": "toastty-interrupt-\(identity)-\(lifecycleCounter)",
            "request": ["subtype": "interrupt"],
        ])
    }

    /// Answers the request that waits under `responseID`. A request takes
    /// one answer: after `submitted`, the same ID gives `notPending`.
    public mutating func answer(
        responseID: String,
        answers: [RemoteInteractionAnswer],
        at date: Date
    ) -> AnswerOutcome {
        guard let index = pendingRequests.firstIndex(where: { $0.requestID == responseID }) else {
            return .notPending
        }
        let request = pendingRequests[index]
        guard let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] else {
            return .invalid
        }
        var response: [String: Any]
        let acceptedAnswers: [RemoteInteractionAnswer]?
        switch request.form {
        case .question(let questions):
            guard let canonical = ClaudeQuestionValidation.canonicalAnswers(answers, for: questions),
                  let providerAnswers = ClaudeQuestionValidation.providerAnswers(answers, for: questions) else {
                return .invalid
            }
            var updatedInput = input
            updatedInput["answers"] = providerAnswers
            response = ["behavior": "allow", "updatedInput": updatedInput]
            acceptedAnswers = canonical
        case .permission(let permission):
            guard let decision = permission.decision(answers: answers, denyMessage: ClaudePermissionHook.directDenyMessage),
                  let decisionData = try? JSONEncoder().encode(decision),
                  let decisionObject = (try? JSONSerialization.jsonObject(with: decisionData)) as? [String: Any] else {
                return .invalid
            }
            response = decisionObject
            if response["behavior"] as? String == "allow" {
                response["updatedInput"] = input
            } else {
                deniedRequestInTurn = true
            }
            acceptedAnswers = nil
        }
        pendingRequests.remove(at: index)
        let line = Self.line([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": request.requestID, "response": response] as [String: Any],
        ])
        return .submitted(line: line, observations: [resolvedObservation(
            request,
            resolution: .resolved,
            answers: acceptedAnswers,
            at: date
        )])
    }

    // MARK: - The state now

    /// The turn state and the waiting requests as observations, for a
    /// projection that starts to read this session after it began: one that
    /// was built again, or one that read only the transcript file so far.
    /// Empty until the session is ready.
    public mutating func currentStateObservations(at date: Date) -> [ProviderTranscriptObservation] {
        guard phase == .ready else { return [] }
        guard isTurnRunning else {
            return [lifecycleObservation(.turnEnded(turnID: nil, reason: .completed), label: "prompt_open", at: date)]
        }
        return [lifecycleObservation(.turnStarted(turnID: nil), label: "turn_running", at: date)]
            + pendingRequests.map { presentedObservation($0, at: date) }
    }

    // MARK: - Lines the process writes

    public mutating func receive(line: String, at date: Date) -> [Output] {
        if case .failed = phase { return [] }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }
        switch type {
        case "control_response":
            return receiveControlResponse(object, at: date)
        case "system":
            return receiveSystem(object, at: date)
        case "user", "assistant":
            return receiveMessage(object, at: date)
        case "result":
            let isFinal = object["stop_reason"] as? String == "end_turn"
            return flushHeldText(as: isFinal ? .final : .commentary) + receiveResult(object, at: date)
        case "control_request":
            return flushHeldText(as: .commentary) + receiveControlRequest(object, at: date)
        case "control_cancel_request":
            return receiveControlCancel(object, at: date)
        default:
            // Partial text, rate limits, command lifecycle: not needed for
            // the conversation or its state.
            return []
        }
    }

    private mutating func receiveControlResponse(_ object: [String: Any], at date: Date) -> [Output] {
        guard let response = object["response"] as? [String: Any],
              let requestID = response["request_id"] as? String,
              requestID == startRequestID, phase == .starting else {
            return []
        }
        guard response["subtype"] as? String == "success",
              let body = response["response"] as? [String: Any] else {
            let reason = (response["error"] as? String) ?? "no reason given"
            return fail("Claude Code refused Toastty's start request: \(reason).")
        }
        let accountBody = body["account"] as? [String: Any]
        let account = Account(
            subscriptionType: Self.nonEmpty(accountBody?["subscriptionType"]),
            apiProvider: Self.nonEmpty(accountBody?["apiProvider"]),
            claudeCodeVersion: Self.nonEmpty(body["claude_code_version"]),
            permissionMode: Self.nonEmpty(body["current_permission_mode"])
        )
        self.account = account
        if requirements.requiresPlanSignIn, account.subscriptionType == nil {
            return fail(
                "Claude Code started without a Claude plan sign-in, so its work would be billed another way or would fail. "
                    + "Toastty sent it no message. Sign in with `claude auth login`, then start the coordinator again."
            )
        }
        if requirements.anyOfCommands.isEmpty == false {
            let offered = Set((body["commands"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            if offered.isDisjoint(with: requirements.anyOfCommands) {
                return fail(
                    "Claude Code started without Toastty's skills (it offers none of: "
                        + requirements.anyOfCommands.joined(separator: ", ")
                        + "). Toastty sent it no message."
                )
            }
        }
        phase = .ready
        return [
            .ready(account),
            .observations([lifecycleObservation(.turnEnded(turnID: nil, reason: .completed), label: "prompt_open", at: date)]),
        ]
    }

    private mutating func receiveSystem(_ object: [String: Any], at date: Date) -> [Output] {
        switch object["subtype"] as? String {
        case "init":
            if let sessionID = Self.nonEmpty(object["session_id"]) {
                nativeSessionID = sessionID
            }
            // Claude names the source of an API key here. A plan sign-in
            // has none. Stop before this turn's request can use a key.
            if requirements.requiresPlanSignIn,
               let keySource = Self.nonEmpty(object["apiKeySource"]), keySource != "none" {
                return fail(
                    "Claude Code would bill an API key (\(keySource)) and not the Claude plan. Toastty stopped it. "
                        + "Remove the key from Toastty's environment, then start the coordinator again."
                )
            }
            return flushHeldText(as: .commentary) + turnStartedOutputs(at: date)
        case "status":
            let status = Self.nonEmpty(object["status"])
            isCompacting = status == "compacting"
            return status == nil ? [] : turnStartedOutputs(at: date)
        case "compact_boundary":
            let recordID = Self.nonEmpty(object["uuid"]) ?? "\(identity):\(nextLifecycleNumber())"
            return [.observations([ProviderTranscriptObservation(
                timestamp: date,
                fingerprint: "compact_boundary:\(recordID)",
                payload: .contextCompacted,
                mayAuthorizeCurrentRuntime: false
            )])]
        default:
            return []
        }
    }

    private mutating func receiveMessage(_ object: [String: Any], at date: Date) -> [Output] {
        var outputs: [Output] = []
        // A subagent's messages belong to a tool call of the root turn, and
        // a background subagent can write them while no root turn runs.
        let isRootMessage = Self.nonEmpty(object["parent_tool_use_id"]) == nil
        let recordedAt = ClaudeTranscriptParser.streamTimestamp(object["timestamp"]) ?? date
        if isRootMessage, recordedAt >= startedAt {
            outputs += turnStartedOutputs(at: date)
        }
        let message = object["message"] as? [String: Any]
        let messageID = message?["id"] as? String
        let blockTypes = (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        if isRootMessage,
           object["type"] as? String == "user" || messageID != heldTextMessageID || blockTypes.contains("tool_use") {
            outputs += flushHeldText(as: .commentary)
        }
        // The stream gives each part of Claude's answer before the answer
        // has its stop reason. The transcript file's record has it.
        let lacksStopReason = Self.nonEmpty(message?["stop_reason"]) == nil
        let sentMessage = (object["uuid"] as? String).flatMap { sentMessages[$0] }
        var observations: [ProviderTranscriptObservation] = []
        for var observation in parser.parseStreamMessage(object, receivedAt: date) {
            // The turn's end is this session's `result`, not the marker
            // record that Claude writes for an interrupt.
            if case .turnEnded = observation.payload { continue }
            observation.mayAuthorizeCurrentRuntime = false
            if let sentMessage, case .transcript(.userMessage(var payload)) = observation.payload {
                // Claude took the host's message: this is its receipt.
                payload.origin = .remote
                payload.clientRequestID = sentMessage.clientRequestID
                payload.deliveryMode = sentMessage.deliveryMode == .prompt ? nil : sentMessage.deliveryMode
                observation.payload = .transcript(.userMessage(payload))
            }
            if lacksStopReason, case .transcript(.assistantMessage) = observation.payload {
                heldText.append(observation)
                heldTextMessageID = messageID
                continue
            }
            observations.append(observation)
        }
        if observations.isEmpty == false {
            outputs.append(.observations(observations))
        }
        return outputs
    }

    private mutating func receiveResult(_ object: [String: Any], at date: Date) -> [Output] {
        var outputs: [Output] = []
        // A command that Claude answers by itself, such as `/context`, can
        // give its result with no earlier sign of a turn. The message that
        // asked for it used the prompt, so the prompt must open again.
        outputs += turnStartedOutputs(at: date)

        // Only the host stops a turn here: with an interrupt request, or
        // with a deny. Any other end with an error is a failure, such as a
        // turn that Claude Code could not set up.
        let subtype = object["subtype"] as? String
        let endedWithError = object["is_error"] as? Bool == true || (subtype != nil && subtype != "success")
        let interrupted = endedWithError && (interruptRequested || deniedRequestInTurn)
        let failed = endedWithError && interrupted == false
        var answeredIDs = (object["user_message_uuids"] as? [String]) ?? []
        if answeredIDs.isEmpty, let single = object["user_message_uuid"] as? String {
            answeredIDs = [single]
        }
        isTurnRunning = false
        isCompacting = false
        interruptRequested = false
        deniedRequestInTurn = false
        // Claude withdraws the requests of a turn that ended.
        pendingRequests.removeAll()
        outputs.append(.observations([lifecycleObservation(
            .turnEnded(turnID: nil, reason: interrupted ? .aborted : .completed),
            label: "turn_ended",
            at: date
        )]))
        outputs.append(.turnEnded(TurnEnd(
            clientRequestIDs: answeredIDs.compactMap { sentMessages[$0]?.clientRequestID },
            failed: failed,
            interrupted: interrupted,
            queuedTurnCount: (object["queued_turn_count"] as? Int) ?? 0
        )))
        return outputs
    }

    private mutating func receiveControlRequest(_ object: [String: Any], at date: Date) -> [Output] {
        guard let requestID = object["request_id"] as? String,
              let request = object["request"] as? [String: Any] else { return [] }
        guard request["subtype"] as? String == "can_use_tool",
              let toolName = Self.nonEmpty(request["tool_name"]),
              let toolUseID = Self.nonEmpty(request["tool_use_id"]),
              let input = request["input"] as? [String: Any],
              let inputJSON = try? JSONSerialization.data(withJSONObject: input),
              let inputValue = try? JSONDecoder().decode([String: AutomationJSONValue].self, from: inputJSON) else {
            // Claude waits for an answer to each request. One that this
            // host cannot serve gets an error, so the turn goes on or ends.
            return [.write(Self.line([
                "type": "control_response",
                "response": ["subtype": "error", "request_id": requestID, "error": "Toastty does not support this request."],
            ]))]
        }
        // Claude can ask again for the same tool call. One request waits
        // for each call: the newest.
        pendingRequests.removeAll { $0.toolUseID == toolUseID }

        let displayName = Self.nonEmpty(request["display_name"]) ?? toolName
        let form: PendingRequest.Form
        let prompt: String
        if toolName == "AskUserQuestion" {
            // An allow without answers is no answer to a question.
            guard let questions = ClaudeQuestionValidation.questions(fromToolInput: inputValue["questions"]) else {
                return [.write(Self.denyLine(requestID: requestID, message: "Toastty cannot show this question to the user."))]
            }
            form = .question(questions)
            prompt = questions[0].question
        } else if request["requires_user_interaction"] as? Bool == true,
                  Self.approvalIsTheInteraction.contains(toolName) == false {
            // The tool needs a form of its own, which Toastty does not
            // have. Allow and Deny would not be that form.
            return [.write(Self.denyLine(requestID: requestID, message: "Toastty cannot show this request to the user."))]
        } else {
            let reason = Self.nonEmpty(request["decision_reason"])
            let summary = reason.map { "\(displayName): \($0)" } ?? "Claude Code asks to use \(displayName)"
            let suggestionsValue = (request["permission_suggestions"] as? [Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(AutomationJSONValue.self, from: $0) }
            guard let permission = ClaudePermissionHook(
                toolName: toolName,
                toolInput: inputValue,
                suggestions: suggestionsValue,
                summary: summary,
                anyTool: true
            ), permission.presentation.detail.previewTruncated == false else {
                // Nobody can read this request in full, so nobody can
                // approve it: no terminal shows the rest of it.
                return [.write(Self.denyLine(
                    requestID: requestID,
                    message: "The request is too long for Toastty to show in full, so the user cannot approve it."
                ))]
            }
            form = .permission(permission)
            prompt = summary
        }
        let pending = PendingRequest(
            requestID: requestID,
            toolUseID: toolUseID,
            toolName: toolName,
            inputJSON: inputJSON,
            form: form,
            prompt: prompt,
            presentedAt: date
        )
        pendingRequests.append(pending)
        return turnStartedOutputs(at: date) + [.observations([presentedObservation(pending, at: date)])]
    }

    private mutating func receiveControlCancel(_ object: [String: Any], at date: Date) -> [Output] {
        guard let requestID = object["request_id"] as? String,
              let index = pendingRequests.firstIndex(where: { $0.requestID == requestID }) else { return [] }
        let request = pendingRequests.remove(at: index)
        return [.observations([resolvedObservation(request, resolution: .superseded, answers: nil, at: date)])]
    }

    // MARK: - Observations

    /// Gives the assistant text that waited to learn whether it is the
    /// turn's final answer. The transcript file's record says so with the
    /// answer's stop reason, which the stream's message does not have yet.
    /// What comes next says it: more work in the turn makes the text
    /// commentary, and the turn's `result` with the stop reason `end_turn`
    /// makes it the final answer. The file's record and this observation
    /// have one fingerprint, so they must agree.
    private mutating func flushHeldText(as phase: ConversationAssistantMessagePhase) -> [Output] {
        guard heldText.isEmpty == false else { return [] }
        let observations = heldText.map { held -> ProviderTranscriptObservation in
            guard case .transcript(.assistantMessage(var payload)) = held.payload else { return held }
            payload.phase = phase
            var observation = held
            observation.payload = .transcript(.assistantMessage(payload))
            return observation
        }
        heldText.removeAll()
        heldTextMessageID = nil
        return [.observations(observations)]
    }

    private mutating func turnStartedOutputs(at date: Date) -> [Output] {
        guard phase == .ready, isTurnRunning == false else { return [] }
        isTurnRunning = true
        interruptRequested = false
        deniedRequestInTurn = false
        return [.observations([lifecycleObservation(.turnStarted(turnID: nil), label: "turn_started", at: date)])]
    }

    private mutating func nextLifecycleNumber() -> Int {
        lifecycleCounter += 1
        return lifecycleCounter
    }

    private mutating func lifecycleObservation(
        _ payload: ProviderObservationPayload,
        label: String,
        at date: Date
    ) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: date,
            providerIdentity: nativeSessionID,
            fingerprint: "claude-stream:\(identity):\(nextLifecycleNumber()):\(label)",
            payload: payload
        )
    }

    private func presentedObservation(_ request: PendingRequest, at date: Date) -> ProviderTranscriptObservation {
        let interaction: ProviderInteractionObservation
        switch request.form {
        case .question(let questions):
            interaction = ProviderInteractionObservation(
                kind: .question,
                providerCallID: request.toolUseID,
                prompt: request.prompt,
                options: questions[0].options,
                questions: questions,
                responseID: request.requestID
            )
        case .permission(let permission):
            interaction = ProviderInteractionObservation(
                kind: .permission,
                providerCallID: request.toolUseID,
                prompt: request.prompt,
                options: permission.presentation.decision.options,
                questions: [permission.presentation.decision],
                responseID: request.requestID,
                permission: permission.presentation.detail
            )
        }
        return ProviderTranscriptObservation(
            timestamp: request.presentedAt,
            providerIdentity: request.toolUseID,
            fingerprint: "claude-stream:\(identity):request:\(request.requestID)",
            payload: .interactionPresented(interaction)
        )
    }

    private func resolvedObservation(
        _ request: PendingRequest,
        resolution: RemotePendingInteraction.State,
        answers: [RemoteInteractionAnswer]?,
        at date: Date
    ) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: date,
            providerIdentity: request.toolUseID,
            fingerprint: "claude-stream:\(identity):request:\(request.requestID):\(resolution.rawValue)",
            payload: .transcript(.interactionResolved(ConversationInteractionResolvedPayload(
                interactionID: ConversationProjector.interactionID(provider: .claude, providerCallID: request.toolUseID),
                resolution: resolution,
                answers: answers
            )))
        )
    }

    private mutating func fail(_ reason: String) -> [Output] {
        phase = .failed(reason)
        isTurnRunning = false
        pendingRequests.removeAll()
        heldText.removeAll()
        return [.failed(reason)]
    }

    /// Tools that need the user and take a plain approval as that: the plan
    /// is the request's input, and Allow approves it.
    private static let approvalIsTheInteraction: Set<String> = ["ExitPlanMode"]

    private static func denyLine(requestID: String, message: String) -> String {
        line([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": ["behavior": "deny", "message": message],
            ] as [String: Any],
        ])
    }

    // MARK: - JSON

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One JSON object on one line. Sorted keys keep the bytes the same for
    /// the same message.
    private static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("a stream line is made of JSON values only")
        }
        return text
    }
}
