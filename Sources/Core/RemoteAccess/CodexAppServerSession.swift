import Foundation
import RemoteProtocol

/// One conversation with a Codex process that the host runs itself:
/// `codex app-server` on its standard input and output.
///
/// The process and the host exchange one JSON object for each line: requests
/// with an `id` and a `method`, their responses with the same `id`, and
/// notifications with a `method` only. Both sides send requests. This value
/// makes each line that the host writes, and turns each line that Codex
/// writes into conversation observations and a known state: whether a turn
/// runs, which requests wait for an answer, and which of the host's messages
/// Codex took. It does no input or output itself, so a test can drive it
/// with recorded lines.
///
/// What it reports, and why the host can rely on it:
/// - **A message's receipt.** The host gives each message its own ID
///   (`clientUserMessageId`). Codex writes the message back as a user item
///   with that ID (`clientId`) when it takes it, so a receipt names its
///   message exactly.
/// - **A turn's start and end.** Codex writes `turn/started` and one
///   `turn/completed` for each turn, with the status `completed`,
///   `interrupted` or `failed`.
/// - **A request for an approval or an answer.** Codex asks with a request
///   of its own and waits for the response. Each request takes one
///   response: the first valid answer. Codex ignores a second one.
///
/// Message content is not lifecycle here, as in `ClaudeStreamSession`. The
/// transcript rows come from `CodexRolloutTranscriptParser`, with the
/// fingerprints of the rollout file's records where Codex gives an item the
/// same ID in both places: user messages, Codex's messages and subagent
/// activity. A tool call does not have that: the file names the model's
/// call, and the app-server names the command that ran.
///
/// The shapes are those of Codex 0.172.0, observed with the real program.
public struct CodexAppServerSession: DirectSessionDriver {
    /// What must hold before the first message goes to the process.
    public struct Requirements: Equatable, Sendable {
        /// The process must use the user's ChatGPT plan sign-in. With an
        /// API key, Codex would bill the key.
        public var requiresPlanSignIn: Bool
        /// The process must offer at least one of these skills, such as the
        /// name of a skill that the host delivers. Empty checks nothing.
        public var anyOfSkills: [String]

        public init(requiresPlanSignIn: Bool = true, anyOfSkills: [String] = []) {
            self.requiresPlanSignIn = requiresPlanSignIn
            self.anyOfSkills = anyOfSkills
        }
    }

    /// The conversation to start or to go on with, and its settings. A
    /// `nil` setting leaves the value of Codex's own configuration.
    public struct ThreadSettings: Equatable, Sendable {
        public var directory: String
        /// Codex's ID of the conversation to go on with, or `nil` for a new
        /// one.
        public var resumeThreadID: String?
        public var model: String?
        /// `untrusted`, `on-request` or `never`.
        public var approvalPolicy: String?
        /// `read-only`, `workspace-write` or `danger-full-access`.
        public var sandbox: String?

        public init(
            directory: String,
            resumeThreadID: String? = nil,
            model: String? = nil,
            approvalPolicy: String? = nil,
            sandbox: String? = nil
        ) {
            self.directory = directory
            self.resumeThreadID = resumeThreadID
            self.model = model
            self.approvalPolicy = approvalPolicy
            self.sandbox = sandbox
        }
    }

    /// The text of a message that asks Codex to compact the conversation.
    /// Codex's terminal reads it as a command. The app-server has a request
    /// for it, and would give the text to the model as a message.
    public static let compactCommand = "/compact"

    /// Notifications that this host does not read. Codex sends several for
    /// each word that the model writes.
    static let unusedNotifications = [
        "item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta",
        "item/reasoning/summaryPartAdded", "item/reasoning/textDelta",
        "item/commandExecution/outputDelta", "item/fileChange/outputDelta", "item/fileChange/patchUpdated",
        "thread/tokenUsage/updated", "account/rateLimits/updated", "turn/moderationMetadata",
        "turn/diff/updated", "app/list/updated", "mcpServer/startupStatus/updated",
    ]

    public private(set) var phase: DirectSessionPhase = .starting
    /// Codex's own ID of the conversation and its rollout file, from the
    /// answer to the thread request.
    public private(set) var conversation: DirectSessionConversation?
    public private(set) var isTurnRunning = false

    private let requirements: Requirements
    private let settings: ThreadSettings
    /// Names this process in fingerprints, so the lifecycle observations of
    /// a later process of the same conversation are new ones.
    private let identity: String
    private let clientVersion: String
    private var requestCounter = 0
    private var ownRequests: [Int: OwnRequest] = [:]
    private var lifecycleCounter = 0
    private var parser = CodexRolloutTranscriptParser()
    private var activeTurnID: String?
    /// The host's IDs of the messages that Codex took in the running turn.
    private var turnClientRequestIDs: [String] = []
    /// Codex's text for the error that ends the running turn.
    private var turnErrorMessage: String?
    /// Codex's last message of the running turn.
    private var turnLastMessage: String?
    private var sentMessages: [String: RemoteMessageDeliveryMode] = [:]
    private var sentMessageOrder: [String] = []
    private var pendingRequests: [PendingRequest] = []
    /// What each file change of the running turn would write, by item ID. A
    /// request to approve a change names only the item.
    private var fileChangePreviews: [String: String] = [:]
    /// What the log says about the start, as the answers to the start
    /// requests give it.
    private var startDetails: [String: String] = [:]

    private static let rememberedSentMessages = 256

    private enum OwnRequest: Equatable, Sendable {
        case initialize
        case account
        case skills
        case thread
        case turnStart
        /// A message for the running turn. When Codex has no such turn any
        /// more, the message starts a turn of its own.
        case steer(text: String, clientRequestID: String)
        case interrupt
        case compact(clientRequestID: String)
    }

    /// The `id` of a request that Codex sent: a number or a string.
    private enum ServerRequestID: Equatable, Sendable {
        case number(Int)
        case string(String)

        init?(_ value: Any?) {
            if let string = value as? String {
                self = .string(string)
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                self = .number(number.intValue)
            } else {
                return nil
            }
        }

        var jsonValue: Any {
            switch self {
            case .number(let value): value
            case .string(let value): value
            }
        }

        var text: String {
            switch self {
            case .number(let value): "n\(value)"
            case .string(let value): "s\(value)"
            }
        }
    }

    private enum Decision: Equatable, Sendable {
        case accept
        case acceptForSession
        /// Allow, and stop asking for commands that start with these words.
        case acceptWithRule([String])
        /// Codex goes on with the turn without the action.
        case decline
        /// Codex stops the turn.
        case cancel

        var jsonValue: Any {
            switch self {
            case .accept: "accept"
            case .acceptForSession: "acceptForSession"
            case .acceptWithRule(let words):
                ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": words]] as [String: Any]
            case .decline: "decline"
            case .cancel: "cancel"
            }
        }
    }

    private struct PendingRequest: Equatable, Sendable {
        enum Form: Equatable, Sendable {
            /// The questions, and Codex's own ID of each in their order.
            case question([RemoteInteractionQuestion])
            case permission(
                decision: RemoteInteractionQuestion,
                detail: RemotePermissionRequestDetail,
                decisionsByOptionID: [String: Decision]
            )
        }

        var serverRequestID: ServerRequestID
        var responseID: String
        /// The item, or the one approval of several for an item.
        var callID: String
        var turnID: String?
        var form: Form
        var prompt: String
        var presentedAt: Date
    }

    public init(
        requirements: Requirements = Requirements(),
        settings: ThreadSettings,
        clientVersion: String = "1",
        identity: String = UUID().uuidString
    ) {
        self.requirements = requirements
        self.settings = settings
        self.clientVersion = clientVersion
        self.identity = identity
    }

    /// The IDs of the requests that wait for an answer, oldest first.
    public var pendingResponseIDs: [String] {
        pendingRequests.map(\.responseID)
    }

    public var waitingRequest: DirectSessionWaitingRequest? {
        pendingRequests.first.map { request in
            switch request.form {
            case .question:
                DirectSessionWaitingRequest(requestID: request.responseID, permissionSummary: nil)
            case .permission:
                DirectSessionWaitingRequest(requestID: request.responseID, permissionSummary: request.prompt)
            }
        }
    }

    // MARK: - Lines the host writes

    /// The first line the host writes. Codex answers each start request
    /// before it gets any message, so the requirements are checked before
    /// a message can cost anything: its account, its skills, and then the
    /// conversation itself.
    public mutating func startLines() -> [String] {
        [requestLine(.initialize, method: "initialize", params: [
            "clientInfo": ["name": "toastty", "title": "Toastty", "version": clientVersion],
            "capabilities": [
                // The request for the user's answer to a question is in
                // the part of the protocol that Codex marks experimental.
                "experimentalApi": true,
                "requestAttestation": false,
                "optOutNotificationMethods": Self.unusedNotifications,
            ] as [String: Any],
        ])]
    }

    public mutating func messageLine(
        text: String,
        clientRequestID: String,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) -> String? {
        guard phase == .ready, let threadID = conversation?.nativeSessionID else { return nil }
        sentMessages[clientRequestID] = deliveryMode
        sentMessageOrder.append(clientRequestID)
        if sentMessageOrder.count > Self.rememberedSentMessages {
            sentMessages.removeValue(forKey: sentMessageOrder.removeFirst())
        }
        if isTurnRunning == false, text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.compactCommand {
            return requestLine(.compact(clientRequestID: clientRequestID), method: "thread/compact/start", params: [
                "threadId": threadID,
            ])
        }
        if deliveryMode == .steer, isTurnRunning, let activeTurnID {
            return requestLine(.steer(text: text, clientRequestID: clientRequestID), method: "turn/steer", params: [
                "threadId": threadID,
                "expectedTurnId": activeTurnID,
                "clientUserMessageId": clientRequestID,
                "input": Self.textInput(text),
            ])
        }
        return turnStartLine(text: text, clientRequestID: clientRequestID, threadID: threadID)
    }

    /// A message that starts a turn. While a turn runs, Codex puts the
    /// message into that turn.
    private mutating func turnStartLine(text: String, clientRequestID: String, threadID: String) -> String {
        requestLine(.turnStart, method: "turn/start", params: [
            "threadId": threadID,
            "clientUserMessageId": clientRequestID,
            "input": Self.textInput(text),
        ])
    }

    public mutating func interruptLine() -> String? {
        guard phase == .ready, isTurnRunning,
              let threadID = conversation?.nativeSessionID, let activeTurnID else { return nil }
        return requestLine(.interrupt, method: "turn/interrupt", params: [
            "threadId": threadID,
            "turnId": activeTurnID,
        ])
    }

    public mutating func answer(
        responseID: String,
        answers: [RemoteInteractionAnswer],
        at date: Date
    ) -> DirectSessionAnswerOutcome {
        guard let index = pendingRequests.firstIndex(where: { $0.responseID == responseID }) else {
            return .notPending
        }
        let request = pendingRequests[index]
        let result: [String: Any]
        let acceptedAnswers: [RemoteInteractionAnswer]?
        switch request.form {
        case .question(let questions):
            guard let canonical = RemoteQuestionAnswerValidation.canonicalAnswers(answers, for: questions) else {
                return .invalid
            }
            var byQuestion: [String: Any] = [:]
            for (question, answer) in zip(questions, canonical) {
                let selected = Set(answer.selectedOptionIDs)
                var parts = question.options.filter { selected.contains($0.id) }.map(\.label)
                if let text = answer.text { parts.append(text) }
                byQuestion[question.id] = ["answers": parts]
            }
            result = ["answers": byQuestion]
            acceptedAnswers = canonical
        case .permission(let decision, _, let decisionsByOptionID):
            guard let choice = ClaudePermissionDecision.decision(from: answers, for: decision),
                  let codexDecision = decisionsByOptionID[choice.optionID] else {
                return .invalid
            }
            result = ["decision": codexDecision.jsonValue]
            acceptedAnswers = nil
        }
        pendingRequests.remove(at: index)
        let line = Self.jsonLine(["id": request.serverRequestID.jsonValue, "result": result])
        return .submitted(line: line, observations: [resolvedObservation(
            request,
            resolution: .resolved,
            answers: acceptedAnswers,
            at: date
        )])
    }

    // MARK: - The state now

    public mutating func currentStateObservations(at date: Date) -> [ProviderTranscriptObservation] {
        guard phase == .ready else { return [] }
        guard isTurnRunning else {
            return [lifecycleObservation(.turnEnded(turnID: nil, reason: .completed), label: "prompt_open", at: date)]
        }
        return [lifecycleObservation(.turnStarted(turnID: activeTurnID), label: "turn_running", at: date)]
            + pendingRequests.map { presentedObservation($0) }
    }

    // MARK: - Lines the process writes

    public mutating func receive(line: String, at date: Date) -> [DirectSessionOutput] {
        if case .failed = phase { return [] }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if object["id"] != nil {
                guard let requestID = ServerRequestID(object["id"]) else { return [] }
                return receiveServerRequest(method, requestID: requestID, params: params, at: date)
            }
            return receiveNotification(method, params: params, at: date)
        }
        guard let id = (object["id"] as? NSNumber)?.intValue,
              let request = ownRequests.removeValue(forKey: id) else { return [] }
        if let result = object["result"] as? [String: Any] {
            return receiveResult(result, for: request, at: date)
        }
        let error = object["error"] as? [String: Any]
        return receiveError(Self.nonEmptyString(error?["message"]) ?? "no reason given", for: request, at: date)
    }

    private mutating func receiveResult(
        _ result: [String: Any],
        for request: OwnRequest,
        at date: Date
    ) -> [DirectSessionOutput] {
        switch request {
        case .initialize:
            return [
                .write(Self.jsonLine(["method": "initialized"])),
                .write(requestLine(.account, method: "account/read", params: ["refreshToken": false])),
            ]

        case .account:
            let account = result["account"] as? [String: Any]
            if requirements.requiresPlanSignIn, account?["type"] as? String != "chatgpt" {
                let found = Self.nonEmptyString(account?["type"]).map { "It uses \"\($0)\"." } ?? "It has no sign-in."
                return fail(
                    "Codex started without a ChatGPT plan sign-in, so its work would be billed another way or would fail. "
                        + "\(found) Toastty sent it no message. Sign in with `codex login`, then start the coordinator again."
                )
            }
            startDetails["plan"] = Self.nonEmptyString(account?["planType"]) ?? "none"
            guard requirements.anyOfSkills.isEmpty else {
                return [.write(requestLine(.skills, method: "skills/list", params: ["cwds": [settings.directory]]))]
            }
            return [.write(threadRequestLine())]

        case .skills:
            let offered = Set((result["data"] as? [[String: Any]] ?? [])
                .flatMap { $0["skills"] as? [[String: Any]] ?? [] }
                .filter { $0["enabled"] as? Bool != false }
                .compactMap { $0["name"] as? String })
            if offered.isDisjoint(with: requirements.anyOfSkills) {
                return fail(
                    "Codex started without Toastty's skills (it offers none of: "
                        + requirements.anyOfSkills.joined(separator: ", ")
                        + "). Toastty sent it no message."
                )
            }
            return [.write(threadRequestLine())]

        case .thread:
            guard let thread = result["thread"] as? [String: Any],
                  let threadID = Self.nonEmptyString(thread["id"]),
                  let path = Self.nonEmptyString(thread["path"]) else {
                return fail("Codex gave Toastty no saved conversation to work in. Toastty sent it no message.")
            }
            let conversation = DirectSessionConversation(nativeSessionID: threadID, transcriptPath: path)
            self.conversation = conversation
            phase = .ready
            startDetails["codex_version"] = Self.nonEmptyString(thread["cliVersion"]) ?? "unknown"
            startDetails["approval_policy"] = (result["approvalPolicy"] as? String) ?? "custom"
            startDetails["approvals_reviewer"] = Self.nonEmptyString(result["approvalsReviewer"]) ?? "unknown"
            // The instruction files that Codex read for the conversation,
            // such as the folder's AGENTS.md.
            startDetails["instruction_sources"] = (result["instructionSources"] as? [String] ?? []).joined(separator: ", ")
            var observations: [ProviderTranscriptObservation] = []
            let profile = RemoteSessionExecutionProfile(
                modelIdentifier: Self.nonEmptyString(result["model"]),
                reasoningEffort: Self.nonEmptyString(result["reasoningEffort"])
            )
            if profile.isEmpty == false {
                observations.append(lifecycleObservation(.executionProfileReported(profile), label: "profile", at: date))
            }
            observations.append(lifecycleObservation(.turnEnded(turnID: nil, reason: .completed), label: "prompt_open", at: date))
            return [.conversation(conversation), .ready(details: startDetails), .observations(observations)]

        case .turnStart:
            guard let turn = result["turn"] as? [String: Any], let turnID = Self.nonEmptyString(turn["id"]) else { return [] }
            return turnStartedOutputs(turnID: turnID, at: date)

        case .compact(let clientRequestID):
            // Codex writes no user message for this request. Its answer is
            // the receipt of the message that asked for it, and the turn
            // that compacts starts next.
            sentMessages.removeValue(forKey: clientRequestID)
            turnClientRequestIDs.append(clientRequestID)
            return [.observations([compactReceipt(clientRequestID: clientRequestID, at: date)])]

        case .steer, .interrupt:
            return []
        }
    }

    private mutating func compactReceipt(clientRequestID: String, at date: Date) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: date,
            fingerprint: "codex-app-server:\(identity):compact:\(nextLifecycleNumber())",
            payload: .transcript(.userMessage(ConversationUserMessagePayload(
                text: Self.compactCommand,
                origin: .remote,
                clientRequestID: clientRequestID
            ))),
            mayAuthorizeCurrentRuntime: false
        )
    }

    private mutating func receiveError(
        _ message: String,
        for request: OwnRequest,
        at date: Date
    ) -> [DirectSessionOutput] {
        switch request {
        case .initialize:
            return fail("Codex refused Toastty's start request: \(message).")
        case .account:
            return fail("Codex did not tell Toastty which account it uses: \(message). Toastty sent it no message.")
        case .skills:
            return fail("Codex did not tell Toastty which skills it offers: \(message). Toastty sent it no message.")
        case .thread:
            return fail(
                settings.resumeThreadID == nil
                    ? "Codex did not start a conversation: \(message)."
                    : "Codex could not go on with the saved conversation: \(message)."
            )
        case .steer(let text, let clientRequestID):
            // The turn ended before Codex read the message. It starts a
            // turn of its own, so the message is not lost.
            guard phase == .ready, let threadID = conversation?.nativeSessionID else { return [] }
            return [.write(turnStartLine(text: text, clientRequestID: clientRequestID, threadID: threadID))]
        case .turnStart:
            return fail("Codex refused a message from Toastty: \(message).")
        case .compact(let clientRequestID):
            // Codex has nothing to compact, or cannot now. The message
            // that asked was taken, and no turn follows.
            sentMessages.removeValue(forKey: clientRequestID)
            return [.observations([compactReceipt(clientRequestID: clientRequestID, at: date)])]
        case .interrupt:
            // No turn runs any more.
            return []
        }
    }

    private mutating func receiveNotification(
        _ method: String,
        params: [String: Any],
        at date: Date
    ) -> [DirectSessionOutput] {
        switch method {
        case "account/updated":
            // A sign-in can change while the process runs. Stop before the
            // next request can bill an API key.
            if requirements.requiresPlanSignIn, let mode = Self.nonEmptyString(params["authMode"]),
               mode.hasPrefix("chatgpt") == false {
                return fail(
                    "Codex changed to a sign-in that is not a ChatGPT plan (\(mode)). Toastty stopped it. "
                        + "Sign in with `codex login`, then start the coordinator again."
                )
            }
            return []
        default:
            break
        }
        // Everything else belongs to one conversation. A subagent's thread
        // reports through the same process.
        guard phase == .ready, let threadID = conversation?.nativeSessionID,
              params["threadId"] as? String == threadID else { return [] }
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let turnID = Self.nonEmptyString(turn["id"]) else { return [] }
            return turnStartedOutputs(turnID: turnID, at: date)
        case "turn/completed":
            return receiveTurnCompleted(params["turn"] as? [String: Any] ?? [:], at: date)
        case "item/started":
            return receiveItem(params, completed: false, at: date)
        case "item/completed":
            return receiveItem(params, completed: true, at: date)
        case "error":
            if params["willRetry"] as? Bool != true {
                turnErrorMessage = Self.nonEmptyString((params["error"] as? [String: Any])?["message"])
            }
            return []
        case "serverRequest/resolved":
            // Codex withdrew a request: the turn ended, or another client
            // of the same process answered. An answer from this host took
            // the request out already.
            guard let requestID = ServerRequestID(params["requestId"]),
                  let index = pendingRequests.firstIndex(where: { $0.serverRequestID == requestID }) else { return [] }
            let request = pendingRequests.remove(at: index)
            return [.observations([resolvedObservation(request, resolution: .superseded, answers: nil, at: date)])]
        default:
            return []
        }
    }

    private mutating func receiveTurnCompleted(_ turn: [String: Any], at date: Date) -> [DirectSessionOutput] {
        // Only the turn that runs can end. Codex reports each turn's start
        // before its end.
        guard isTurnRunning else { return [] }
        if let activeTurnID, let endedTurnID = Self.nonEmptyString(turn["id"]), endedTurnID != activeTurnID {
            return []
        }
        var outputs: [DirectSessionOutput] = []
        let status = turn["status"] as? String
        let interrupted = status == "interrupted"
        let failed = status == "failed"
        let errorMessage = (Self.nonEmptyString((turn["error"] as? [String: Any])?["message"]) ?? turnErrorMessage)
            .map(Self.readableError)
        let answered = turnClientRequestIDs
        let turnID = activeTurnID
        let lastMessage = turnLastMessage
        isTurnRunning = false
        activeTurnID = nil
        turnClientRequestIDs = []
        turnErrorMessage = nil
        turnLastMessage = nil
        fileChangePreviews = [:]
        // Codex withdraws the requests of a turn that ended.
        pendingRequests.removeAll()
        outputs.append(.observations([lifecycleObservation(
            .turnEnded(turnID: turnID, reason: interrupted ? .aborted : .completed),
            label: "turn_ended",
            at: date
        )]))
        outputs.append(.turnEnded(DirectSessionTurnEnd(
            clientRequestIDs: answered,
            failed: failed,
            interrupted: interrupted,
            errorMessage: failed ? errorMessage : nil,
            lastMessage: lastMessage
        )))
        return outputs
    }

    // MARK: - Items

    private mutating func receiveItem(_ params: [String: Any], completed: Bool, at date: Date) -> [DirectSessionOutput] {
        guard let item = params["item"] as? [String: Any],
              let type = item["type"] as? String,
              let itemID = Self.nonEmptyString(item["id"]) else { return [] }
        let turnID = Self.nonEmptyString(params["turnId"])
        // An item is no sign of a running turn: a command can end after
        // the turn that started it.
        var outputs: [DirectSessionOutput] = []
        let milliseconds = (item[completed ? "completedAtMs" : "startedAtMs"] as? NSNumber)?.doubleValue
        let recordedAt = milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } ?? date

        var records: [[String: Any]] = []
        switch (type, completed) {
        case ("userMessage", true):
            let text = (item["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            records.append(Self.eventRecord([
                "type": "item_completed",
                "turn_id": turnID ?? NSNull(),
                "item": ["type": "UserMessage", "id": itemID, "content": [["type": "text", "text": text]]] as [String: Any],
            ]))
        case ("agentMessage", true):
            turnLastMessage = Self.nonEmptyString(item["text"]) ?? turnLastMessage
            records.append(Self.responseRecord([
                "type": "message",
                "role": "assistant",
                "id": itemID,
                "phase": item["phase"] ?? NSNull(),
                "content": [["type": "output_text", "text": item["text"] as? String ?? ""]],
            ], turnID: turnID))
        case ("subAgentActivity", true):
            records.append(Self.eventRecord([
                "type": "sub_agent_activity",
                "event_id": itemID,
                "kind": item["kind"] ?? NSNull(),
                "agent_thread_id": item["agentThreadId"] ?? NSNull(),
                "agent_path": item["agentPath"] ?? NSNull(),
            ]))
        case ("contextCompaction", true):
            records.append(Self.eventRecord(["type": "context_compacted"]))
        case ("fileChange", false):
            fileChangePreviews[itemID] = Self.fileChangePreview(item["changes"])
            fallthrough
        default:
            if let call = Self.toolCall(type: type, item: item) {
                records.append(completed
                    ? Self.responseRecord([
                        "type": "function_call_output", "call_id": itemID, "output": call.output,
                    ], turnID: turnID)
                    : Self.responseRecord([
                        "type": "function_call", "call_id": itemID, "name": call.name, "arguments": call.arguments,
                    ], turnID: turnID))
            }
        }

        var observations: [ProviderTranscriptObservation] = []
        for record in records {
            var record = record
            record["timestamp"] = recordedAt.formatted(Self.timestampStyle)
            for var observation in parser.parseLine(Self.jsonLine(record)) {
                // The rows have no say over the prompt: the turn's start
                // and end are this session's own observations.
                observation.mayAuthorizeCurrentRuntime = false
                if type == "userMessage", let clientID = Self.nonEmptyString(item["clientId"]),
                   let deliveryMode = sentMessages[clientID],
                   case .transcript(.userMessage(var payload)) = observation.payload {
                    // Codex took the host's message: this is its receipt.
                    payload.origin = .remote
                    payload.clientRequestID = clientID
                    payload.deliveryMode = deliveryMode == .prompt ? nil : deliveryMode
                    observation.payload = .transcript(.userMessage(payload))
                    if isTurnRunning, turnClientRequestIDs.contains(clientID) == false {
                        turnClientRequestIDs.append(clientID)
                    }
                }
                observations.append(observation)
            }
        }
        if observations.isEmpty == false {
            outputs.append(.observations(observations))
        }
        return outputs
    }

    /// Codex gives the model provider's error as the JSON that the provider
    /// sent. Its message is what a person reads.
    static func readableError(_ message: String) -> String {
        guard let start = message.firstIndex(of: "{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(message[start...].utf8))) as? [String: Any],
              let inner = nonEmptyString((object["error"] as? [String: Any])?["message"]) else { return message }
        let prefix = message[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? inner : "\(prefix) \(inner)"
    }

    /// A tool call as the rollout file's record of a function call has it:
    /// the name, the arguments as JSON text, and the output once it ended.
    /// `nil` for an item that is no tool call.
    private static func toolCall(type: String, item: [String: Any]) -> (name: String, arguments: String, output: String)? {
        let name: String
        var arguments: [String: Any] = [:]
        var result = ""
        switch type {
        case "commandExecution":
            name = "exec_command"
            arguments["cmd"] = item["command"] as? String ?? ""
            result = (item["aggregatedOutput"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
        case "fileChange":
            name = "apply_patch"
            arguments["cmd"] = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.joined(separator: ", ")
        case "mcpToolCall":
            name = "mcp__\(item["server"] as? String ?? "server")__\(item["tool"] as? String ?? "tool")"
            arguments = item["arguments"] as? [String: Any] ?? [:]
            result = nonEmptyString((item["error"] as? [String: Any])?["message"]) ?? ""
        case "dynamicToolCall":
            name = item["tool"] as? String ?? "tool"
            arguments = item["arguments"] as? [String: Any] ?? [:]
        case "collabAgentToolCall":
            name = item["tool"] as? String ?? "agent"
            arguments["cmd"] = item["prompt"] as? String ?? ""
        case "webSearch":
            name = "web_search"
            arguments["cmd"] = item["query"] as? String ?? ""
        default:
            return nil
        }
        // The parser reads the outcome from the line that Codex's own
        // record of a command's output has.
        let exitCode: Int? = switch item["status"] as? String {
        case "completed": (item["exitCode"] as? NSNumber)?.intValue ?? ((item["success"] as? Bool) == false ? 1 : 0)
        case "failed": (item["exitCode"] as? NSNumber)?.intValue ?? 1
        default: nil
        }
        let outcome = exitCode.map { "Process exited with code \($0)" } ?? (item["status"] as? String ?? "")
        let argumentsText = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (name, argumentsText, result.isEmpty ? outcome : "\(result)\n\(outcome)")
    }

    private static func fileChangePreview(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).map { change in
            let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? "change"
            let path = change["path"] as? String ?? "a file"
            let diff = change["diff"] as? String ?? ""
            return diff.isEmpty ? "\(kind) \(path)" : "\(kind) \(path)\n\(diff)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Requests from Codex

    private mutating func receiveServerRequest(
        _ method: String,
        requestID: ServerRequestID,
        params: [String: Any],
        at date: Date
    ) -> [DirectSessionOutput] {
        guard phase == .ready, let threadID = conversation?.nativeSessionID else {
            return [.write(Self.errorLine(requestID, "Toastty is not ready for this request."))]
        }
        let turnID = Self.nonEmptyString(params["turnId"])
        let itemID = Self.nonEmptyString(params["itemId"])
        // A subagent's thread asks through the same process. Toastty shows
        // the requests of the coordinator's own conversation only.
        let isOwnThread = params["threadId"] as? String == threadID
        let form: PendingRequest.Form
        let prompt: String
        let callID: String
        switch method {
        case "item/commandExecution/requestApproval":
            guard isOwnThread, let itemID else {
                return [.write(Self.resultLine(requestID, ["decision": Decision.decline.jsonValue]))]
            }
            let reason = Self.nonEmptyString(params["reason"])
            let network = params["networkApprovalContext"] as? [String: Any]
            let preview: String
            let summary: String
            if let command = Self.nonEmptyString(params["command"]) {
                preview = Self.nonEmptyString(params["cwd"]).map { "\(command)\n\nin \($0)" } ?? command
                summary = reason.map { "Codex asks to run a command: \($0)" } ?? "Codex asks to run a command"
            } else if let host = Self.nonEmptyString(network?["host"]) {
                preview = [Self.nonEmptyString(network?["protocol"]), host].compactMap { $0 }.joined(separator: " ")
                summary = reason.map { "Codex asks for network access: \($0)" } ?? "Codex asks for network access"
            } else {
                return [.write(Self.resultLine(requestID, ["decision": Decision.decline.jsonValue]))]
            }
            var offered: [Decision] = []
            for value in params["availableDecisions"] as? [Any] ?? ["accept", "cancel"] {
                switch value as? String {
                case "accept": offered.append(.accept)
                case "acceptForSession": offered.append(.acceptForSession)
                case "decline": offered.append(.decline)
                case "cancel": offered.append(.cancel)
                default:
                    if let amendment = (value as? [String: Any])?["acceptWithExecpolicyAmendment"] as? [String: Any],
                       let words = amendment["execpolicy_amendment"] as? [String], words.isEmpty == false {
                        offered.append(.acceptWithRule(words))
                    }
                }
            }
            guard let permission = Self.permissionForm(
                toolName: "Shell command", summary: summary, description: reason, preview: preview, offered: offered
            ) else {
                // Nobody can read this request in full, or it has no
                // answer that Toastty can offer. Codex goes on without it.
                return [.write(Self.resultLine(requestID, ["decision": Decision.decline.jsonValue]))]
            }
            form = permission
            prompt = summary
            callID = Self.nonEmptyString(params["approvalId"]) ?? itemID

        case "item/fileChange/requestApproval":
            guard isOwnThread, let itemID, let preview = fileChangePreviews[itemID], preview.isEmpty == false else {
                return [.write(Self.resultLine(requestID, ["decision": Decision.decline.jsonValue]))]
            }
            let reason = Self.nonEmptyString(params["reason"])
            let summary = reason.map { "Codex asks to change files: \($0)" } ?? "Codex asks to change files"
            guard let permission = Self.permissionForm(
                toolName: "File change", summary: summary, description: reason, preview: preview,
                offered: [.accept, .cancel]
            ) else {
                return [.write(Self.resultLine(requestID, ["decision": Decision.decline.jsonValue]))]
            }
            form = permission
            prompt = summary
            callID = itemID

        case "item/tool/requestUserInput":
            guard isOwnThread, let itemID, let questions = Self.questions(params["questions"]) else {
                // No answer is the answer to a question that Toastty cannot
                // show: Codex goes on without it.
                return [.write(Self.resultLine(requestID, ["answers": [String: Any]()]))]
            }
            form = .question(questions)
            prompt = questions[0].question
            callID = itemID

        case "item/permissions/requestApproval":
            // More permissions for the turn. Toastty has no form that says
            // exactly what they allow, so it grants none.
            return [.write(Self.resultLine(requestID, ["permissions": [String: Any](), "scope": "turn"]))]

        case "mcpServer/elicitation/request":
            return [.write(Self.resultLine(requestID, ["action": "decline", "content": NSNull(), "_meta": NSNull()]))]

        default:
            // Codex waits for an answer to each request. One that this
            // host cannot serve gets an error, so the turn goes on or ends.
            return [.write(Self.errorLine(requestID, "Toastty does not support this request."))]
        }
        // Codex can ask again for the same call. One request waits for
        // each call: the newest.
        var outputs: [DirectSessionOutput] = []
        pendingRequests.removeAll { $0.callID == callID }
        let pending = PendingRequest(
            serverRequestID: requestID,
            responseID: "codex-app-server:\(identity):\(requestID.text)",
            callID: callID,
            turnID: turnID,
            form: form,
            prompt: prompt,
            presentedAt: date
        )
        pendingRequests.append(pending)
        outputs.append(.observations([presentedObservation(pending)]))
        return outputs
    }

    /// What a client shows for an approval request, and Codex's decision
    /// for each choice. `nil` when the preview is too long to show in full,
    /// or when Codex offers no way to allow or no way to deny.
    private static func permissionForm(
        toolName: String,
        summary: String,
        description: String?,
        preview: String,
        offered: [Decision]
    ) -> PendingRequest.Form? {
        guard preview.utf8.count <= ClaudePermissionHook.maximumPreviewBytes, offered.contains(.accept) else { return nil }
        var options = [RemotePendingInteraction.Option(id: ClaudePermissionDecision.allowOnce.optionID, label: "Allow once")]
        var decisions: [String: Decision] = [ClaudePermissionDecision.allowOnce.optionID: .accept]
        var alwaysIndex = 0
        for decision in offered where alwaysIndex < ClaudePermissionHook.maximumAlwaysOptions {
            let label: String
            let detail: String
            switch decision {
            case .acceptWithRule(let words):
                let prefix = words.joined(separator: " ")
                // Never shorten a rule: the label must state exactly what
                // is allowed.
                guard prefix.count <= ClaudePermissionHook.maximumRuleLabelLength,
                      prefix.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { continue }
                label = "Always allow commands that start with \(prefix)"
                detail = "Codex saves this rule and does not ask for such commands again"
            case .acceptForSession:
                label = "Allow for this session"
                detail = "Until this Codex session ends"
            default:
                continue
            }
            let optionID = ClaudePermissionDecision.alwaysAllow(suggestionIndex: alwaysIndex).optionID
            options.append(.init(id: optionID, label: label, detail: detail))
            decisions[optionID] = decision
            alwaysIndex += 1
        }
        // Codex's own "No" stops the turn, so the user can say what to do
        // in place of the action.
        if offered.contains(.cancel) {
            options.append(.init(id: ClaudePermissionDecision.deny.optionID, label: "Deny",
                                 detail: "Stops Codex so you can say what to do instead"))
            decisions[ClaudePermissionDecision.deny.optionID] = .cancel
        } else if offered.contains(.decline) {
            options.append(.init(id: ClaudePermissionDecision.deny.optionID, label: "Deny",
                                 detail: "Codex goes on without it"))
            decisions[ClaudePermissionDecision.deny.optionID] = .decline
        } else {
            return nil
        }
        let decision = RemoteInteractionQuestion(
            id: ClaudePermissionDecision.questionID,
            header: toolName,
            question: [summary, preview].filter { $0.isEmpty == false }.joined(separator: "\n\n"),
            options: options
        )
        guard RemoteQuestionAnswerValidation.supports([decision]) else { return nil }
        return .permission(
            decision: decision,
            detail: RemotePermissionRequestDetail(toolName: toolName, description: description, preview: preview),
            decisionsByOptionID: decisions
        )
    }

    /// The questions of a request for the user's input, with Codex's own ID
    /// of each. `nil` when a client cannot show and answer them: a question
    /// with no choices, or one whose answer is a secret.
    private static func questions(_ value: Any?) -> [RemoteInteractionQuestion]? {
        guard let rawQuestions = value as? [[String: Any]] else { return nil }
        var questions: [RemoteInteractionQuestion] = []
        for rawQuestion in rawQuestions {
            guard let id = nonEmptyString(rawQuestion["id"]),
                  let text = nonEmptyString(rawQuestion["question"]),
                  rawQuestion["isSecret"] as? Bool != true,
                  let rawOptions = rawQuestion["options"] as? [[String: Any]] else { return nil }
            let options = rawOptions.enumerated().compactMap { index, option -> RemotePendingInteraction.Option? in
                guard let label = nonEmptyString(option["label"]) else { return nil }
                return .init(id: "\(id):o\(index)", label: label, detail: nonEmptyString(option["description"]))
            }
            guard options.count == rawOptions.count else { return nil }
            questions.append(.init(id: id, header: nonEmptyString(rawQuestion["header"]) ?? "Question", question: text, options: options))
        }
        return RemoteQuestionAnswerValidation.supports(questions) ? questions : nil
    }

    // MARK: - Observations

    private mutating func turnStartedOutputs(turnID: String?, at date: Date) -> [DirectSessionOutput] {
        guard phase == .ready else { return [] }
        if let turnID { activeTurnID = turnID }
        guard isTurnRunning == false else { return [] }
        isTurnRunning = true
        turnErrorMessage = nil
        turnLastMessage = nil
        return [
            .observations([lifecycleObservation(.turnStarted(turnID: activeTurnID), label: "turn_started", at: date)]),
            .turnStarted,
        ]
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
            providerIdentity: conversation?.nativeSessionID,
            fingerprint: "codex-app-server:\(identity):\(nextLifecycleNumber()):\(label)",
            payload: payload
        )
    }

    private func presentedObservation(_ request: PendingRequest) -> ProviderTranscriptObservation {
        let interaction: ProviderInteractionObservation
        switch request.form {
        case .question(let questions):
            interaction = ProviderInteractionObservation(
                kind: .question,
                providerCallID: request.callID,
                prompt: request.prompt,
                options: questions[0].options,
                questions: questions,
                responseID: request.responseID
            )
        case .permission(let decision, let detail, _):
            interaction = ProviderInteractionObservation(
                kind: .permission,
                providerCallID: request.callID,
                prompt: request.prompt,
                options: decision.options,
                questions: [decision],
                responseID: request.responseID,
                permission: detail
            )
        }
        return ProviderTranscriptObservation(
            timestamp: request.presentedAt,
            turnID: request.turnID,
            providerIdentity: request.callID,
            fingerprint: "codex-app-server:\(identity):request:\(request.serverRequestID.text)",
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
            turnID: request.turnID,
            providerIdentity: request.callID,
            fingerprint: "codex-app-server:\(identity):request:\(request.serverRequestID.text):\(resolution.rawValue)",
            payload: .transcript(.interactionResolved(ConversationInteractionResolvedPayload(
                interactionID: ConversationProjector.interactionID(provider: .codex, providerCallID: request.callID),
                resolution: resolution,
                answers: answers
            )))
        )
    }

    private mutating func fail(_ reason: String) -> [DirectSessionOutput] {
        phase = .failed(reason)
        isTurnRunning = false
        activeTurnID = nil
        pendingRequests.removeAll()
        ownRequests.removeAll()
        return [.failed(reason)]
    }

    // MARK: - JSON

    private mutating func requestLine(_ request: OwnRequest, method: String, params: [String: Any]) -> String {
        requestCounter += 1
        ownRequests[requestCounter] = request
        return Self.jsonLine(["id": requestCounter, "method": method, "params": params])
    }

    private mutating func threadRequestLine() -> String {
        var params: [String: Any] = ["cwd": settings.directory]
        if let model = settings.model { params["model"] = model }
        if let approvalPolicy = settings.approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if let sandbox = settings.sandbox { params["sandbox"] = sandbox }
        guard let resumeThreadID = settings.resumeThreadID else {
            return requestLine(.thread, method: "thread/start", params: params)
        }
        params["threadId"] = resumeThreadID
        // The rollout file gives the history.
        params["excludeTurns"] = true
        return requestLine(.thread, method: "thread/resume", params: params)
    }

    private static func textInput(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text, "text_elements": [Any]()]]
    }

    private static func resultLine(_ requestID: ServerRequestID, _ result: [String: Any]) -> String {
        jsonLine(["id": requestID.jsonValue, "result": result])
    }

    private static func errorLine(_ requestID: ServerRequestID, _ message: String) -> String {
        jsonLine(["id": requestID.jsonValue, "error": ["code": -32601, "message": message] as [String: Any]])
    }

    /// A record as the rollout file has it, for `CodexRolloutTranscriptParser`.
    private static func eventRecord(_ payload: [String: Any]) -> [String: Any] {
        ["type": "event_msg", "payload": payload]
    }

    private static func responseRecord(_ payload: [String: Any], turnID: String?) -> [String: Any] {
        var payload = payload
        if let turnID {
            payload["internal_chat_message_metadata_passthrough"] = ["turn_id": turnID]
        }
        return ["type": "response_item", "payload": payload]
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
